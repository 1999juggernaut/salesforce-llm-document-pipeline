"""Callback client: posts the job result back to the Salesforce Apex REST endpoint."""
from __future__ import annotations

import json
import logging
import shutil
import subprocess
from functools import lru_cache
from urllib.parse import urlparse

import requests

from config import RETRY_ATTEMPTS, RETRY_BASE_DELAY_S, SF_ACCESS_TOKEN, SF_TARGET_ORG
from retry import with_retries

log = logging.getLogger(__name__)
CALLBACK_PATH = "/services/apexrest/invoice-callback"


@lru_cache(maxsize=1)
def _cli_access_token() -> str:
    """Local-dev fallback: read the access token of an authenticated `sf` CLI org."""
    sf = shutil.which("sf") or shutil.which("sf.cmd")
    if not sf or not SF_TARGET_ORG:
        return ""
    try:
        out = subprocess.run([sf, "org", "display", "--target-org", SF_TARGET_ORG, "--json"],
                             capture_output=True, text=True, check=True, timeout=60).stdout
        return (json.loads(out).get("result") or {}).get("accessToken", "") or ""
    except Exception as exc:  # noqa: BLE001
        log.warning("could not read access token from sf CLI: %s", exc)
        return ""


def access_token() -> str:
    return SF_ACCESS_TOKEN or _cli_access_token()


def validate_callback_url(url: str) -> None:
    """Only post back to an HTTPS Salesforce Apex REST endpoint (prevents open-callback abuse)."""
    p = urlparse(url)
    host = p.hostname or ""
    if p.scheme != "https" or not p.path.endswith(CALLBACK_PATH) or not (
        host.endswith(".salesforce.com") or host.endswith(".force.com") or host.endswith(".salesforce-sites.com")
    ):
        raise ValueError("callback_url must be an https Salesforce Apex REST URL ending in " + CALLBACK_PATH)


def post_result(callback_url: str, payload: dict, callback_token: str) -> dict:
    headers = {"Content-Type": "application/json", "X-Callback-Token": callback_token}
    token = access_token()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    else:
        log.warning("no Salesforce access token available; callback will likely get 401")

    def call() -> dict:
        r = requests.post(callback_url, json=payload, headers=headers, timeout=30)
        r.raise_for_status()
        return r.json() if r.text else {}

    return with_retries(call, attempts=RETRY_ATTEMPTS, base_delay=RETRY_BASE_DELAY_S, what="Salesforce callback")
