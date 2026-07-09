# Tools — the Execution (WAT Layer 3)

Python scripts that do the actual, deterministic work: API calls, data
transformations, file operations, database queries. These should be consistent,
testable, and fast.

## Conventions

- **Target Python 3.6+, standard library only.** CI agents run Python 3.6.8 in an
  airgapped environment, so scripts must not use 3.7+ syntax (no PEP 585 `list[...]`,
  no PEP 604 `X | None`, no `from __future__ import annotations`) and must not require
  `pip install` — no third-party packages. Use `typing.List`/`Optional` for annotations.
- One script per task, verb-first, snake_case — e.g. `scrape_single_site.py`.
- Read credentials from `.env` (via environment variables). Never hard-code
  secrets, and never store them anywhere but `.env`.
- Fail loudly with clear error messages and non-zero exit codes so the agent can
  react and recover.
- Write intermediates to `.tmp/`; final deliverables go to cloud services.

## Before adding a new tool

Check whether an existing script already covers the task. Only create a new one
when nothing here fits.
