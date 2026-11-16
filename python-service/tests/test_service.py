"""Service tests. Docling, the LLM and Salesforce are stubbed, so these run offline in seconds."""
import base64

import pytest
import requests
from fastapi.testclient import TestClient

import app as service
import retry
import salesforce_client

CALLBACK = "https://example-dev-ed.develop.my.salesforce.com/services/apexrest/invoice-callback"


def body(**over):
    b = {
        "file_name": "invoice.pdf",
        "file_base64": base64.b64encode(b"%PDF-1.4 fake").decode(),
        "salesforce_record_id": "068000000000001AAA",
        "callback_url": CALLBACK,
        "callback_token": "s3cret-token",
        "user_query": "What is the invoice total?",
    }
    b.update(over)
    return b


@pytest.fixture(autouse=True)
def stubs(monkeypatch):
    service._jobs.clear()
    service._by_key.clear()
    calls = {"callbacks": [], "prompts": []}
    monkeypatch.setattr(service, "convert_document", lambda data, name: "Invoice total: 245.75 USD")
    monkeypatch.setattr(service, "ask_llm", lambda p: calls["prompts"].append(p) or "The total is 245.75 USD.")
    monkeypatch.setattr(service, "post_result", lambda url, payload, tok: calls["callbacks"].append((url, payload, tok)) or {})
    return calls


client = TestClient(service.app)


def test_health():
    assert client.get("/health").json() == {"status": "ok"}


def test_submit_processes_and_calls_back(stubs):
    r = client.post("/extract", json=body())
    assert r.status_code == 202 and r.json()["status"] == "accepted"
    job_id = r.json()["job_id"]
    # TestClient runs background tasks before returning, so the job is finished here.
    status = client.get(f"/jobs/{job_id}").json()
    assert status["status"] == "succeeded" and status["callback"] == "delivered"
    url, payload, token = stubs["callbacks"][0]
    assert url == CALLBACK and token == "s3cret-token"
    assert payload["job_id"] == job_id and payload["data"]["response_text"] == "The total is 245.75 USD."
    assert "245.75" in stubs["prompts"][0] and "What is the invoice total?" in stubs["prompts"][0]


def test_duplicate_submission_is_not_processed_twice(stubs):
    first = client.post("/extract", json=body()).json()
    second = client.post("/extract", json=body()).json()
    assert second == {"status": "duplicate", "job_id": first["job_id"], "job_status": "succeeded"}
    assert len(stubs["callbacks"]) == 1


def test_different_task_is_a_new_job(stubs):
    a = client.post("/extract", json=body()).json()
    b = client.post("/extract", json=body(user_query="List the line items")).json()
    assert a["job_id"] != b["job_id"] and len(stubs["callbacks"]) == 2


def test_processing_failure_is_isolated_and_reported(monkeypatch, stubs):
    def boom(data, name):
        raise RuntimeError("corrupt document")

    monkeypatch.setattr(service, "convert_document", boom)
    job_id = client.post("/extract", json=body()).json()["job_id"]
    status = client.get(f"/jobs/{job_id}").json()
    assert status["status"] == "failed" and "corrupt document" in status["error"]
    assert stubs["callbacks"][0][1]["data"]["response_text"] is None  # Salesforce still hears about it
    assert client.get("/health").status_code == 200  # service keeps running
    # a failed job can be retried by re-submitting
    assert client.post("/extract", json=body()).json()["status"] == "accepted"


def test_callback_failure_is_recorded(monkeypatch):
    def down(url, payload, tok):
        raise requests.ConnectionError("salesforce unreachable")

    monkeypatch.setattr(service, "post_result", down)
    job_id = client.post("/extract", json=body()).json()["job_id"]
    status = client.get(f"/jobs/{job_id}").json()
    assert status["callback"] == "failed" and "unreachable" in status["error"]


@pytest.mark.parametrize("over,code", [
    ({"file_base64": "not base64!!"}, 422),
    ({"file_base64": ""}, 422),
    ({"callback_url": "https://evil.example.com/services/apexrest/invoice-callback"}, 422),
    ({"callback_url": "http://x.my.salesforce.com/services/apexrest/invoice-callback"}, 422),
    ({"salesforce_record_id": "123"}, 422),
])
def test_input_validation(over, code):
    assert client.post("/extract", json=body(**over)).status_code == code


def test_oversized_file_rejected(monkeypatch):
    monkeypatch.setattr(service, "MAX_FILE_BYTES", 10)
    assert client.post("/extract", json=body()).status_code == 413


def test_token_not_in_repr():
    assert "s3cret-token" not in repr(service.FileRequest(**body()))


def test_unknown_job_404():
    assert client.get("/jobs/nope").status_code == 404


def test_callback_url_validation():
    salesforce_client.validate_callback_url(CALLBACK)
    with pytest.raises(ValueError):
        salesforce_client.validate_callback_url("https://attacker.com/services/apexrest/invoice-callback")


# --- retry helper ---
def _http_error(code):
    resp = requests.Response()
    resp.status_code = code
    return requests.HTTPError(response=resp)


def test_retry_recovers_from_transient_errors():
    attempts = {"n": 0}

    def flaky():
        attempts["n"] += 1
        if attempts["n"] < 3:
            raise _http_error(503)
        return "ok"

    sleeps = []
    assert retry.with_retries(flaky, attempts=3, base_delay=1, what="t", sleep=sleeps.append) == "ok"
    assert attempts["n"] == 3 and len(sleeps) == 2 and sleeps[1] > sleeps[0]  # exponential backoff


def test_retry_gives_up_after_max_attempts():
    with pytest.raises(requests.ConnectionError):
        retry.with_retries(lambda: (_ for _ in ()).throw(requests.ConnectionError()), attempts=2,
                           base_delay=0, what="t", sleep=lambda s: None)


def test_retry_does_not_retry_client_errors():
    calls = {"n": 0}

    def bad():
        calls["n"] += 1
        raise _http_error(400)

    with pytest.raises(requests.HTTPError):
        retry.with_retries(bad, attempts=5, base_delay=0, what="t", sleep=lambda s: None)
    assert calls["n"] == 1
