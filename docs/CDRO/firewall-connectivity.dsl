// ---------------------------------------------------------------------------
// CloudBees CD/RO — firewall / connectivity validation.
//
// Proves the flows in the firewall matrix
// (../vault-integrations/00-architecture-overview.md §4) are actually open,
// from a CD/RO agent, and tells a firewall DROP apart from a service that is
// simply not listening.
//
// This is illustrative CD/RO DSL. Adapt field names to your CD/RO version —
// the procedure shape and the parameter semantics are the contract.
//
// DEPENDENCY-FREE: a plain command step running bash. No plugin, no ectool, no
// python, no jq. The checker degrades to SKIP (with a reason) for any optional
// tool the agent is missing, so a stripped agent still produces a report.
//
// PREREQUISITES
//   1. conn_check.sh and targets.conf present on the agent, by default in
//      /opt/conncheck (override with the conn_check_dir parameter). Deploy them
//      with whatever you already use for agent config — the AAP playbook in
//      ../AAP, Puppet/Chef/Ansible, or a CD/RO artifact. They are two static
//      files; nothing needs to be installed or compiled.
//   2. For hop mode only: an SSH private key readable by the CD/RO agent user
//      (mode 0600). The account it logs in as needs no privilege beyond running
//      bash — the checker only makes outbound connections.
//
// LOAD IT
//   ectool evalDsl --dslFile firewall-connectivity.dsl
//
// RUN IT
//   ectool runProcedure Network-Validation \
//     --procedureName 'Firewall Connectivity Check' \
//     --actualParameter apps=vault,ci envs=prod
//
// STEP OUTCOME
//   exit 0  every flow open
//   exit 1  one or more flows closed — the step goes red. This is a finding.
//   exit 3  a check could NOT be run (SSH to the hop host failed, or a tool is
//           missing). NOT the same as a closed flow — read the log.
//   exit 2  bad catalog or bad parameters; the procedure is misconfigured.
// ---------------------------------------------------------------------------

project 'Network-Validation', {

  procedure 'Firewall Connectivity Check', {
    description = '''Validates the CI/CDRO/AAP <-> Vault firewall matrix from a CD/RO agent.
Distinguishes a firewall DROP (TIMEOUT) from an open path with nothing listening (REFUSED).'''

    formalParameter 'conn_check_dir', defaultValue: '/opt/conncheck', {
      documentation = 'Directory on the agent holding conn_check.sh and targets.conf'
      required = '1'
      type = 'entry'
    }

    formalParameter 'apps', defaultValue: '', {
      documentation = 'Applications to check, comma-separated (blank = all). e.g. vault,ci'
      required = '0'
      type = 'entry'
    }

    formalParameter 'envs', defaultValue: 'prod', {
      documentation = 'Environments to check, comma-separated (blank = all)'
      required = '0'
      type = 'entry'
    }

    formalParameter 'hop', defaultValue: '', {
      documentation = '''HOP name from targets.conf — SSH there and run the checks FROM that host.
"all" runs every hop. Blank checks from this agent.
Flows #1 (Vault -> CI /oidc) and #9 (Vault -> SIEM) originate on a Vault node,
so they can ONLY be validated this way.'''
      required = '0'
      type = 'entry'
    }

    formalParameter 'ssh_key', defaultValue: '', {
      documentation = 'Path on the agent to the SSH private key for hop mode (mode 0600). Ignored unless hop is set.'
      required = '0'
      type = 'entry'
    }

    formalParameter 'check_timeout', defaultValue: '5', {
      documentation = 'Per-check timeout in seconds'
      required = '1'
      type = 'entry'
    }

    formalParameter 'ca_file', defaultValue: '', {
      documentation = 'Optional private CA bundle for TLS verification, e.g. /etc/pki/vault/ca.crt'
      required = '0'
      type = 'entry'
    }

    formalParameter 'insecure_tls', defaultValue: '0', {
      documentation = 'Set to 1 to skip TLS certificate verification'
      required = '0'
      type = 'checkbox'
      checkedValue = '1'
      uncheckedValue = '0'
    }

    step 'run-conn-check', {
      description    = 'Runs conn_check.sh with the requested filters'
      shell          = 'bash'
      timeLimit      = 15
      timeLimitUnits = 'minutes'
      // resourceName = 'cdro-agent-pool'   // pin to the zone you want to test FROM

      command = '''
set -u

# CD/RO substitutes $[...] before bash ever sees this script, so every
# substitution is wrapped in single quotes and validated below.
DIR='$[conn_check_dir]'
APPS='$[apps]'
ENVS='$[envs]'
HOP='$[hop]'
SSH_KEY='$[ssh_key]'
TIMEOUT='$[check_timeout]'
CA_FILE='$[ca_file]'
INSECURE='$[insecure_tls]'

CHECK="$DIR/conn_check.sh"
TARGETS="$DIR/targets.conf"

# --- validation ------------------------------------------------------------
# The filter values are expanded unquoted further down so they word-split into
# flags, so reject anything that is not a plain token first.
validate() {
  case "$1" in
    '') return 0 ;;
    *[!A-Za-z0-9_,.-]*)
      echo "conn_check: parameter '$2' contains unsupported characters: $1" >&2
      exit 2 ;;
  esac
}
validate "$APPS"    apps
validate "$ENVS"    envs
validate "$HOP"     hop
validate "$TIMEOUT" check_timeout

case "$TIMEOUT" in
  ''|*[!0-9]*) echo "conn_check: check_timeout must be a whole number, got '$TIMEOUT'" >&2; exit 2 ;;
esac

if [ ! -x "$CHECK" ]; then
  echo "conn_check: $CHECK not found or not executable." >&2
  echo "            Deploy conn_check.sh and targets.conf to $DIR on this agent." >&2
  exit 2
fi
if [ ! -r "$TARGETS" ]; then
  echo "conn_check: catalog $TARGETS not readable." >&2
  exit 2
fi

# --- build the argument list ------------------------------------------------
# Built with "set --" rather than a string, so every value stays a single
# properly-quoted argument. No eval, no word-splitting surprises.
set -- --file "$TARGETS" --timeout "$TIMEOUT"

[ -n "$ENVS" ]        && set -- "$@" --env "$ENVS"
[ "$INSECURE" = "1" ] && set -- "$@" --insecure
[ -n "$CA_FILE" ]     && set -- "$@" --cafile "$CA_FILE"

if [ -n "$HOP" ]; then
  # Hop mode: the HOP row already declares which applications to test, so
  # 'apps' is deliberately not passed here.
  set -- "$@" --hop "$HOP"
  [ -n "$SSH_KEY" ] && set -- "$@" --ssh-opts "-i $SSH_KEY"
  echo "Running connectivity checks via hop '$HOP' ..."
else
  [ -n "$APPS" ] && set -- "$@" --app "$APPS"
  echo "Running connectivity checks from this agent ..."
fi

RC=0
"$CHECK" "$@" || RC=$?

# --- outcome ---------------------------------------------------------------
case "$RC" in
  0) echo "All connectivity checks passed — every flow is open." ;;
  1) echo "FAILED: one or more flows are closed."
     echo "        TIMEOUT = firewall DROP. REFUSED = path open, nothing listening." ;;
  3) echo "INCONCLUSIVE: some checks could not be run (SSH to the hop host failed,"
     echo "              or a tool is missing on this agent). This is NOT proof that"
     echo "              the flow is closed."
     # To surface this as a CD/RO warning rather than an error, uncomment:
     # ectool setProperty /myJobStep/outcome warning && RC=0
     ;;
  *) echo "Misconfigured: conn_check.sh exited $RC (bad catalog or bad arguments)." ;;
esac

exit $RC
'''
    }
  }
}

// --- Optional: run it as a gate inside a release pipeline -------------------
// Validate the firewall BEFORE the stage that needs those flows open, so a
// closed rule fails fast with a clear message instead of surfacing later as a
// confusing Vault "signature/validation" error.
//
// pipeline 'deploy-with-vault-secrets', {
//   stage 'preflight', {
//     task 'firewall-check', {
//       taskType       : 'PROCEDURE'
//       subproject     : 'Network-Validation'
//       subprocedure   : 'Firewall Connectivity Check'
//       actualParameter: [
//         apps          : 'vault',
//         envs          : 'prod',
//         check_timeout : '5'
//       ]
//     }
//   }
// }
