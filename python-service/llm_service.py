"""LLM call (Ollama /api/generate) with bounded retries."""
from __future__ import annotations

import requests

from config import LLM_TIMEOUT_S, MODEL_NAME, OLLAMA_URL, RETRY_ATTEMPTS, RETRY_BASE_DELAY_S
from retry import with_retries

PROMPT_TEMPLATE = """You are an assistant that extracts information from business documents.
Answer only from the document. If the answer is not in the document, say so.

<document>
{document}
</document>

Task: {task}
"""


def build_prompt(document_text: str, task: str) -> str:
    return PROMPT_TEMPLATE.format(document=document_text, task=task)


def ask_llm(prompt: str) -> str:
    def call() -> str:
        r = requests.post(
            OLLAMA_URL,
            json={"model": MODEL_NAME, "prompt": prompt, "stream": False, "options": {"temperature": 0}},
            timeout=LLM_TIMEOUT_S,
        )
        r.raise_for_status()
        return r.json()["response"]

    return with_retries(call, attempts=RETRY_ATTEMPTS, base_delay=RETRY_BASE_DELAY_S, what="LLM call")
