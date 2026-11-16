"""FastAPI service: accept a document job from Salesforce, process it in the background, call back.

Flow: Salesforce Queueable --POST /extract--> 202 {job_id} ... background: Docling -> LLM -> callback.
Status can be polled with GET /jobs/{job_id} (submit -> poll -> retrieve).
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import logging
import threading
import time
import uuid
from typing import Optional

from fastapi import BackgroundTasks, FastAPI, HTTPException
from pydantic import BaseModel, Field

from config import JOB_TTL_S, MAX_FILE_BYTES
from document_processor import convert_document, limit_context
from llm_service import ask_llm, build_prompt
from retry import first
from salesforce_client import post_result, validate_callback_url

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("doc-service")

app = FastAPI(title="Salesforce LLM Document Service", version="1.1.0")

DEFAULT_TASK = "Summarize this document and extract key business information."


class FileRequest(BaseModel):
    file_name: str = Field(..., max_length=255)
    file_base64: str
    salesforce_record_id: str = Field(..., min_length=15, max_length=18)
    callback_url: str
    callback_token: str = Field(..., repr=False)  # never printed in logs or reprs
    user_query: Optional[str] = Field(None, max_length=4000)
    prompt: Optional[str] = Field(None, max_length=4000)


# --- in-memory job store (one process). Swap for Redis/Firestore when running several replicas. ---
_jobs: dict[str, dict] = {}
_by_key: dict[str, str] = {}
_lock = threading.Lock()


def _idempotency_key(req: FileRequest, file_bytes: bytes) -> str:
    """Same record + same file content + same task => same job (duplicate deliveries are ignored)."""
    h = hashlib.sha256()
    for part in (req.salesforce_record_id, first(req.user_query, req.prompt, DEFAULT_TASK)):
        h.update(part.encode())
    h.update(hashlib.sha256(file_bytes).digest())
    return h.hexdigest()


def _purge_expired(now: float) -> None:
    for jid in [j for j, rec in _jobs.items() if rec["finished_at"] and now - rec["finished_at"] > JOB_TTL_S]:
        _by_key.pop(_jobs[jid]["key"], None)
        _jobs.pop(jid, None)


def _set(job_id: str, **fields) -> None:
    with _lock:
        _jobs[job_id].update(fields)


def process_job(job_id: str, req: FileRequest, file_bytes: bytes) -> None:
    """Background worker. Failures are isolated to this job and reported back to Salesforce."""
    _set(job_id, status="processing", started_at=time.time())
    payload = {"salesforce_record_id": req.salesforce_record_id, "job_id": job_id}
    try:
        text = convert_document(file_bytes, req.file_name)
        text, truncated = limit_context(text)
        answer = ask_llm(build_prompt(text, first(req.user_query, req.prompt, DEFAULT_TASK)))
        payload["data"] = {"response_text": answer, "context_truncated": truncated}
        result_status = "succeeded"
    except Exception as exc:  # noqa: BLE001 - one bad document must not take the service down
        log.exception("job %s failed during processing", job_id)
        payload["data"] = {"response_text": None, "error": type(exc).__name__ + ": " + str(exc)[:500]}
        result_status = "failed"

    try:
        post_result(req.callback_url, payload, req.callback_token)
        _set(job_id, status=result_status, callback="delivered", finished_at=time.time(),
             error=payload["data"].get("error"))
    except Exception as exc:  # noqa: BLE001
        log.error("job %s: callback failed after retries: %s", job_id, exc)
        _set(job_id, status=result_status, callback="failed", finished_at=time.time(),
             error=f"callback failed: {exc}")
    log.info("job %s finished: %s (callback %s)", job_id, _jobs[job_id]["status"], _jobs[job_id]["callback"])


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.post("/extract", status_code=202)
@app.post("/process-document", status_code=202, include_in_schema=False)
def submit(req: FileRequest, background: BackgroundTasks) -> dict:
    try:
        validate_callback_url(req.callback_url)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    try:
        file_bytes = base64.b64decode(req.file_base64, validate=True)
    except (binascii.Error, ValueError):
        raise HTTPException(status_code=422, detail="file_base64 is not valid base64")
    if not file_bytes:
        raise HTTPException(status_code=422, detail="file is empty")
    if len(file_bytes) > MAX_FILE_BYTES:
        raise HTTPException(status_code=413, detail=f"file exceeds {MAX_FILE_BYTES} bytes")

    key = _idempotency_key(req, file_bytes)
    now = time.time()
    with _lock:
        _purge_expired(now)
        existing = _by_key.get(key)
        if existing and _jobs[existing]["status"] in ("queued", "processing", "succeeded"):
            log.info("duplicate submission for record %s -> existing job %s", req.salesforce_record_id, existing)
            return {"status": "duplicate", "job_id": existing, "job_status": _jobs[existing]["status"]}
        job_id = uuid.uuid4().hex
        _jobs[job_id] = {"job_id": job_id, "key": key, "status": "queued", "callback": "pending",
                         "salesforce_record_id": req.salesforce_record_id, "file_name": req.file_name,
                         "submitted_at": now, "started_at": None, "finished_at": None, "error": None}
        _by_key[key] = job_id

    log.info("accepted job %s for record %s (%s, %d bytes)", job_id, req.salesforce_record_id, req.file_name,
             len(file_bytes))
    background.add_task(process_job, job_id, req, file_bytes)
    return {"status": "accepted", "job_id": job_id}


@app.get("/jobs/{job_id}")
def job_status(job_id: str) -> dict:
    with _lock:
        rec = _jobs.get(job_id)
        if not rec:
            raise HTTPException(status_code=404, detail="unknown or expired job")
        return {k: v for k, v in rec.items() if k != "key"}
