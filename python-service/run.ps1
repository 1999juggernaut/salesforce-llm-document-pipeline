Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if (-not (Test-Path '.venv')) { python -m venv .venv; .\.venv\Scripts\python -m pip install -r requirements.txt }
.\.venv\Scripts\python -m uvicorn app:app --host 0.0.0.0 --port 8000
