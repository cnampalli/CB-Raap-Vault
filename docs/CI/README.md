# CloudBees CI — firewall connectivity validation

`Jenkinsfile.firewall-connectivity` runs the
[shared connectivity checker](../shared/) from a CI agent to prove the flows in
the [firewall matrix](../vault-integrations/00-architecture-overview.md#4-firewall-matrix)
are actually open.

---

## Plugins

Core Pipeline steps only: `checkout`, `sh`, `withEnv`, `fileExists`,
`archiveArtifacts`, `deleteDir`. Two exceptions, both bundled with CloudBees CI
and both optional:

| Step | Plugin | When it is reached |
|---|---|---|
| `withCredentials(sshUserPrivateKey)` | Credentials Binding | Only when `HOP` is set |
| `junit` | JUnit | Only when `PUBLISH_JUNIT` is true — turn it off if the plugin is absent |

This follows the same convention as
[`Jenkinsfile.vault-oidc-nocli`](../vault-integrations/examples/Jenkinsfile.vault-oidc-nocli),
which omits `timestamps()` because it needs the Timestamper plugin.

**Agent requirement: bash.** Nothing else. Checks needing a tool the agent lacks
report `SKIP` with the reason, so a stripped agent still produces a usable
report.

---

## Setup

1. Pipeline job pointing at this repo, script path
   `docs/CI/Jenkinsfile.firewall-connectivity`.
2. Run it once to register the parameters.
3. For hop mode only: add an **SSH Username with private key** credential and put
   its ID in `SSH_CREDENTIAL_ID` (default `conncheck-ssh-key`).

The pipeline expects `docs/shared/conn_check.sh` and `docs/shared/targets.conf`
in the workspace — adjust `CONN_CHECK` / `TARGETS` in the `environment` block if
your layout differs.

---

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `APPS` | *(all)* | Applications to check, comma-separated |
| `ENVS` | *(all)* | Environments to check, comma-separated |
| `HOP` | *(blank)* | HOP name, or `all`. Blank = check from this agent |
| `CHECK_TIMEOUT` | `5` | Per-check timeout in seconds |
| `INSECURE_TLS` | `false` | Skip TLS verification |
| `CA_FILE` | *(none)* | Private CA bundle on the agent, e.g. `/etc/pki/vault/ca.crt` |
| `SSH_CREDENTIAL_ID` | `conncheck-ssh-key` | Used in hop mode only |
| `PUBLISH_JUNIT` | `true` | Publish results as test results |

Parameters are validated against `[A-Za-z0-9_,.-]` before they reach a shell,
because the filter flags are expanded unquoted so they word-split. Anything else
is rejected with a clear message rather than passed through.

---

## Build results

| Checker exit | Build result | Meaning |
|---|---|---|
| `0` | SUCCESS | Every flow open |
| `1` | UNSTABLE | One or more flows closed — a finding, like a failed test |
| `3` | UNSTABLE | A check could **not** be run (SSH to the hop host failed, or a tool is missing). **Not** proof the flow is closed |
| `2` | FAILURE | Bad catalog or bad parameters — the job is misconfigured |

Want a red build for a closed flow instead of yellow? Change
`currentBuild.result = 'UNSTABLE'` to `'FAILURE'` in the `rc 1` branch of
`applyResult()`.

Results are published as test results and archived as
`connectivity-results.xml`, so trends are visible across builds — a flow that
starts failing after a firewall change shows up immediately.

---

## Hop mode

Flows #1 (Vault → CI `/oidc/**`) and #9 (Vault → SIEM) originate **on a Vault
node**, so running them from a CI agent proves nothing. Set `HOP` to the matching
row in [`../shared/targets.conf`](../shared/targets.conf):

```
HOP|flow1-vault-to-ci|svc_conncheck@vault-01.corp.example.com|ci|...
```

The pipeline SSHes there with the bound credential and runs the checks from that
host. The script is streamed over the SSH connection, so nothing is written to
the Vault node's disk. `APPS` is ignored in hop mode — the `HOP` row already
declares which applications to test.

Flow #1 is worth a scheduled run: it is the most commonly missed rule in the
matrix, and it fails silently in a way that looks like a Vault role
misconfiguration.
