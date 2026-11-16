"""Runtime configuration, read from environment variables (see .env.example)."""
import os


def _int(name: str, default: int) -> int:
    return int(os.getenv(name, str(default)))


def _float(name: str, default: float) -> float:
    return float(os.getenv(name, str(default)))


OLLAMA_URL = os.getenv("OLLAMA_URL", "http://127.0.0.1:11434/api/generate")
MODEL_NAME = os.getenv("MODEL_NAME", "llama3")
LLM_TIMEOUT_S = _int("LLM_TIMEOUT_S", 300)

# Context budget: documents are truncated to this many words before prompting.
MAX_WORDS = _int("MAX_WORDS", 4000)
# Reject payloads above this size (decoded bytes). Salesforce side already caps uploads at ~4.5 MB.
MAX_FILE_BYTES = _int("MAX_FILE_BYTES", 6_000_000)

# Bounded retries with exponential backoff for the LLM call and the Salesforce callback.
RETRY_ATTEMPTS = _int("RETRY_ATTEMPTS", 3)
RETRY_BASE_DELAY_S = _float("RETRY_BASE_DELAY_S", 2.0)

# How long finished job records are kept for status polling and duplicate detection.
JOB_TTL_S = _int("JOB_TTL_S", 3600)

# Salesforce auth for the callback (Apex REST needs an OAuth bearer token):
#   1) SF_ACCESS_TOKEN if set, else 2) `sf org display --target-org $SF_TARGET_ORG`.
SF_ACCESS_TOKEN = os.getenv("SF_ACCESS_TOKEN", "")
SF_TARGET_ORG = os.getenv("SF_TARGET_ORG", "")
