# CloudBees CD/RO — firewall connectivity validation

`firewall-connectivity.dsl` defines a CD/RO procedure that runs the
[shared connectivity checker](../shared/) from a CD/RO agent, proving the flows
in the [firewall matrix](../vault-integrations/00-architecture-overview.md#4-firewall-matrix)
are actually open.

Illustrative DSL — adapt field names to your CD/RO version. The procedure shape
and the parameter semantics are the contract, the same caveat as
[`cdro-zerotrust-native.dsl`](../vault-integrations/examples/cdro-zerotrust-native.dsl).

---

## Dependencies

A plain command step running bash. No plugin, no `ectool`, no python, no `jq`.
Checks that need a tool the agent lacks report `SKIP` with the reason, so a
stripped agent still produces a usable report.

---

## Setup

### 1. Put the two files on the agent

Default location `/opt/conncheck` (override with the `conn_check_dir`
parameter):

```
/opt/conncheck/conn_check.sh     # chmod 0755
/opt/conncheck/targets.conf
```

They are two static files — nothing to install or compile. Deploy them with
whatever already manages agent config: the [AAP playbook](../AAP/), Puppet/Chef,
or a CD/RO artifact.

### 2. Load the DSL

```bash
ectool evalDsl --dslFile firewall-connectivity.dsl
```

This creates the project `Network-Validation` with the procedure
`Firewall Connectivity Check`.

### 3. For hop mode only

Place an SSH private key readable by the CD/RO agent user (mode `0600`) and pass
its path as `ssh_key`. The account it logs in as needs no privilege beyond
running bash — the checker only makes outbound connections.

---

## Run it

```bash
# From the CD/RO agent — covers flow #3 (CD/RO -> Vault)
ectool runProcedure Network-Validation \
  --procedureName 'Firewall Connectivity Check' \
  --actualParameter apps=vault envs=prod

# From a Vault node — the only way to test flow #1
ectool runProcedure Network-Validation \
  --procedureName 'Firewall Connectivity Check' \
  --actualParameter hop=flow1-vault-to-ci ssh_key=/etc/cdro/conncheck.key
```

### Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `conn_check_dir` | `/opt/conncheck` | Where the checker and catalog live on the agent |
| `apps` | *(all)* | Applications to check, comma-separated |
| `envs` | `prod` | Environments to check, comma-separated |
| `hop` | *(blank)* | HOP name, or `all`. Blank = check from this agent |
| `ssh_key` | *(none)* | SSH private key path, hop mode only |
| `check_timeout` | `5` | Per-check timeout in seconds |
| `ca_file` | *(none)* | Private CA bundle, e.g. `/etc/pki/vault/ca.crt` |
| `insecure_tls` | `0` | Set `1` to skip TLS verification |

Parameter values are validated against `[A-Za-z0-9_,.-]` inside the step before
they are used, and the checker is invoked with a `set --` argument list rather
than an `eval`'d string. A value like `vault;rm -rf /` is rejected with exit `2`,
not executed.

---

## Step outcome

| Exit | Meaning |
|---|---|
| `0` | Every flow open |
| `1` | One or more flows closed — the step goes red. `TIMEOUT` = firewall DROP, `REFUSED` = path open but nothing listening |
| `3` | A check could **not** be run (SSH to the hop host failed, or a tool is missing). **Not** proof the flow is closed |
| `2` | Bad catalog or bad parameters — the procedure is misconfigured |

To surface `3` as a CD/RO *warning* rather than an error, uncomment the
`ectool setProperty /myJobStep/outcome warning` line in the step.

---

## Use it as a release gate

The bottom of the DSL has a commented `pipeline` block that runs the check in a
`preflight` stage, before the stage that needs those flows open. A closed rule
then fails fast with a clear message instead of surfacing later as a confusing
Vault signature/validation error — which is
[how these failures usually present](../getting-started/05-verify-and-troubleshoot.md).

Remember there is **no Vault → CD/RO flow** to test: the ZeroTrust plugin signs
its JWT locally and Vault validates it against a static public key, so nothing
like flow #1 exists for CD/RO. See
[03-cdro-zerotrust-jwt.md](../vault-integrations/03-cdro-zerotrust-jwt.md).
