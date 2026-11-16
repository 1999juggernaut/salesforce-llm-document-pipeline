"""Document -> Markdown text with Docling, plus a simple context budget."""
from __future__ import annotations

import os
import tempfile
from functools import lru_cache

from config import MAX_WORDS


@lru_cache(maxsize=1)
def _converter():
    # Imported lazily: Docling loads layout models on first use, which keeps startup and tests fast.
    from docling.document_converter import DocumentConverter

    return DocumentConverter()


def convert_document(file_bytes: bytes, file_name: str) -> str:
    suffix = os.path.splitext(file_name)[1] or ".bin"
    fd, temp_path = tempfile.mkstemp(suffix=suffix)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(file_bytes)
        result = _converter().convert(temp_path)
        return result.document.export_to_markdown()
    finally:
        if os.path.exists(temp_path):
            os.remove(temp_path)


def limit_context(text: str, max_words: int = MAX_WORDS) -> tuple[str, bool]:
    """Truncate to max_words. Returns (text, was_truncated)."""
    words = text.split()
    if len(words) <= max_words:
        return " ".join(words), False
    return " ".join(words[:max_words]), True
