"""Small retry helper: bounded attempts with exponential backoff and jitter."""
from __future__ import annotations

import logging
import random
import time
from typing import Callable, Optional, TypeVar

import requests

log = logging.getLogger(__name__)
T = TypeVar("T")

# Errors worth retrying: network problems, timeouts and 5xx / 429 responses.
RETRYABLE_STATUS = {429, 500, 502, 503, 504}


def is_retryable(exc: Exception) -> bool:
    if isinstance(exc, (requests.ConnectionError, requests.Timeout)):
        return True
    if isinstance(exc, requests.HTTPError) and exc.response is not None:
        return exc.response.status_code in RETRYABLE_STATUS
    return False


def with_retries(fn: Callable[[], T], *, attempts: int, base_delay: float, what: str,
                 sleep: Callable[[float], None] = time.sleep,
                 retry_on: Callable[[Exception], bool] = is_retryable) -> T:
    """Call fn(); retry retryable failures up to `attempts` times in total."""
    for attempt in range(1, attempts + 1):
        try:
            return fn()
        except Exception as exc:  # noqa: BLE001 - re-raised below when not retryable
            if attempt >= attempts or not retry_on(exc):
                raise
            delay = base_delay * (2 ** (attempt - 1)) * random.uniform(0.8, 1.2)
            log.warning("%s failed (attempt %d/%d): %s; retrying in %.1fs", what, attempt, attempts, exc, delay)
            sleep(delay)
    raise RuntimeError("unreachable")  # pragma: no cover


def first(*values: Optional[str]) -> str:
    """Return the first non-empty value (helper for optional prompt fields)."""
    return next((v for v in values if v), "")
