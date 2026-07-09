# Workflows — the Instructions (WAT Layer 1)

Markdown SOPs that define **what to do and how**. Each workflow states:

- **Objective** — what this accomplishes
- **Inputs** — what's required to run it
- **Tools** — which scripts in `tools/` to call, in what order
- **Outputs** — what's produced and where it lands (usually a cloud deliverable)
- **Edge cases** — how to handle known failures, rate limits, and quirks

Written in plain language, as if briefing a teammate. Keep these current: when you
find a better method or hit a recurring issue, update the relevant workflow.

> Don't create or overwrite workflows without asking, unless explicitly told to.

## Naming

One file per workflow, verb-first, snake_case — e.g. `scrape_website.md`,
`sync_vault_secret.md`.
