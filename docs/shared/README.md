# Shared connectivity checker

`conn_check.sh` turns the [firewall matrix](../vault-integrations/00-architecture-overview.md#4-firewall-matrix)
into something you can run. `targets.conf` is the catalog it reads.

One engine, three callers — [AAP](../AAP/), [CloudBees CI](../CI/), and
[CD/RO](../CDRO/) all invoke this same script and only pass filter flags. None of
them parses the catalog, so there is no YAML/JSON handling in Ansible or Groovy
to keep in sync.

---

## Why this exists

Every flow in the matrix crosses a firewall zone and must be explicitly opened.
When one is closed, logins fail with confusing signature/validation errors that
look like configuration problems — the guides say as much in
[05-verify-and-troubleshoot §2](../getting-started/05-verify-and-troubleshoot.md).
This proves the path first.

The distinction that matters most:

| Result | Meaning | What to do |
|---|---|---|
| `PASS` | The path is open | Nothing |
| `TIMEOUT` | No response at all — consistent with a **firewall DROP** | Raise a firewall request |
| `REFUSED` | The packet got there and was rejected — **the path is open**, nothing is listening | Fix the service, not the firewall |
| `FAIL` (dns) | The name does not resolve | Fix DNS; later checks are skipped |
| `SKIP` | The check could not run (tool missing, or DNS already failed) | Not evidence either way |

A tool that reported "failed" for all three middle cases would send you to the
firewall team for problems they cannot fix.

---

## Dependencies

**bash 3.2+. That is the only hard requirement.**

`timeout` is used when present (`timeout`/`gtimeout`); a pure-bash watchdog takes
over when it is not. Everything else is optional and degrades to `SKIP` *with the
reason printed*, never to a false failure:

| Check | Uses | If missing |
|---|---|---|
| `dns` | `getent` → `dscacheutil` → `nslookup` → `host` | `SKIP` |
| `tcp` | bash `/dev/tcp` (a shell builtin — no binary at all) | falls back to `nc` |
| `tls` | `openssl s_client` | `SKIP` |
| `http` | `curl` → `wget` → raw request over `/dev/tcp` | `SKIP` |

No python, no jq, nothing to install on any host.

---

## Usage

```bash
./conn_check.sh                                  # everything in the catalog
./conn_check.sh --app vault,ci --env prod        # a subset
./conn_check.sh --list                           # what would be checked, no probing
./conn_check.sh --hop flow1-vault-to-ci          # run the checks FROM a Vault node
./conn_check.sh --hop all --ssh-opts "-i ~/.ssh/id_conncheck"
./conn_check.sh --format tsv                     # machine-readable
./conn_check.sh --junit results.xml              # CI test reporting
```

`--help` lists every option.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Every check passed |
| `1` | One or more checks failed — a finding |
| `2` | Usage or catalog error — the job is misconfigured |
| `3` | A check could **not** be run (SSH to a hop host failed, or a tool is missing). **Not** the same as a closed flow |

---

## Hop mode

Some flows cannot be tested from where you are sitting. Flow #1 (Vault → CI
`/oidc/**`) and flow #9 (Vault → SIEM) originate **on a Vault node** — running
them from a CI agent proves nothing.

```
HOP|flow1-vault-to-ci|svc_conncheck@vault-01.corp.example.com|ci|...
```

`--hop flow1-vault-to-ci` SSHes to that host and runs the checks there. The
script is streamed over the SSH connection on stdin and the targets are passed as
arguments, so **nothing is written to the hop host's disk** and it needs no
catalog file of its own.

Requirements: key-based SSH (`BatchMode`) to the hop host. The account needs no
privilege beyond running bash — the checker only makes outbound connections.

If SSH itself fails you get exit `3` and an explicit "this flow could NOT be
tested" warning, never a silent pass or a false failure.

> Ansible users have a second option: put the hop host in
> `[connectivity_sources]` in the inventory and use `--tags remote`. Ansible then
> does the SSH for you. See [../AAP/](../AAP/).

---

## Editing the catalog

Pipe-delimited, because parsing JSON in shell would mean `jq` — exactly the
dependency this avoids. `#` comments and blank lines are ignored, whitespace
around fields is trimmed (so you may align columns), and `-` means unset.

```
TARGET | app | hosts | ports | checks | http_path | expect_status | env | owner | notes
HOP    | name | user@via-host[:port] | apps | notes
```

`hosts` and `ports` are comma-separated and expand as a cartesian product, so one
row covers many endpoints:

```
TARGET|vault|vault-01,vault-02,vault-03|8200,8201|dns,tcp|-|-|prod|Vault team|6 checks from one row
```

A malformed row is rejected with the file and line number rather than being
silently skipped.

**Replace the `*.corp.example.com` placeholders with your real endpoints**, and
consider whether real hostnames should be committed if this repo is shared
outside the Automation team.
