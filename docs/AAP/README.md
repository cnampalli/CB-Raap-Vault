# AAP — firewall connectivity validation

Runs the [shared connectivity checker](../shared/) from Ansible Automation
Platform to prove the flows in the
[firewall matrix](../vault-integrations/00-architecture-overview.md#4-firewall-matrix)
are actually open.

| File | Purpose |
|---|---|
| `firewall-connectivity.yml` | The playbook — three modes, selected by tag |
| `inventory.example.ini` | Example `[connectivity_sources]` group |

---

## No collections, no Python on the targets

The playbook uses only `ansible.builtin.{command,script,debug,assert}` — no
collections, so it runs in an airgapped execution environment.

`ansible.builtin.script` is one of the very few modules that needs **no Python
interpreter on the managed node**. It ships the shell script over the existing
SSH connection and runs it there. The managed hosts need nothing but bash.

Python is still required on the AAP controller / execution environment, as it is
for all of Ansible.

> `script` does write the script to a temp path on the target and clean up after
> itself. If you need a check that touches nothing at all, use hop mode
> (mode 3 below), which streams the script over stdin instead.

---

## Three modes

### 1. From the controller — `--tags local`

Checks run on the execution environment itself. Covers flow #7 (AAP → Vault) and
flow #10.

```bash
ansible-playbook firewall-connectivity.yml --tags local
ansible-playbook firewall-connectivity.yml --tags local -e apps=vault -e envs=prod
```

### 2. From each inventory host — `--tags remote`

Checks run **on** each host in `[connectivity_sources]`. This is the
Ansible-native way to validate a flow whose source is another machine: put the
Vault VM in inventory and Ansible SSHes in for you.

```bash
ansible-playbook -i inventory.example.ini firewall-connectivity.yml --tags remote
ansible-playbook -i inventory.example.ini firewall-connectivity.yml --tags remote -e apps=ci
```

The catalog is expanded **once on the controller** and the resulting targets are
passed to each host as `--inline` arguments — the catalog file itself is never
copied to the targets.

The final assert runs after every host has been checked, so one closed flow does
not hide the rest.

### 3. Via an SSH hop — `--tags hop`

Uses the `HOP` rows in [`../shared/targets.conf`](../shared/targets.conf), for
source hosts you do not want in inventory. This is exactly what the CI and CD/RO
jobs do, so use it when you want all three platforms behaving identically.

```bash
ansible-playbook firewall-connectivity.yml --tags hop -e hop=flow1-vault-to-ci
ansible-playbook firewall-connectivity.yml --tags hop -e hop=all \
    -e ssh_opts="-i ~/.ssh/id_conncheck"
```

---

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `apps` | *(all)* | Applications to check, comma-separated |
| `envs` | *(all)* | Environments to check, comma-separated |
| `hop` | *(none)* | HOP name, or `all`. Only used by `--tags hop` |
| `check_timeout` | `5` | Per-check timeout in seconds |
| `ssh_opts` | *(none)* | Extra ssh arguments for hop mode, e.g. `-i /path/key` |
| `conn_check` | `{{ playbook_dir }}/../shared/conn_check.sh` | Path to the checker |
| `targets_file` | `{{ playbook_dir }}/../shared/targets.conf` | Path to the catalog |

---

## As an AAP job template

1. Project pointing at this repo.
2. Job template on `firewall-connectivity.yml`, with the job tags set to
   `local`, `remote`, or `hop`.
3. **Enable Variables → "Prompt on launch"**, or AAP drops the extra vars and
   every run checks everything.
4. For `--tags remote`, attach a machine credential for `svc_conncheck`. That
   account needs no privilege beyond logging in and running bash.

The job goes red when a flow is closed. Read the report in the task output:
`TIMEOUT` means a firewall DROP, `REFUSED` means the path is open and nothing is
listening — a service problem, not a firewall one.

`rc=3` means a check could not be run at all (SSH to a hop host failed, or a tool
is missing). That is **not** proof that the flow is closed.

---

## Which flows can this actually prove?

Flows #1 (Vault → CI `/oidc/**`) and #9 (Vault → SIEM) originate **on a Vault
node**. Running them from the AAP controller proves nothing — use mode 2 with the
Vault nodes in inventory, or mode 3 with the matching `HOP` row. Everything else
in the matrix can be checked from wherever the relevant source lives.
