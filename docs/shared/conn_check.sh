#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# conn_check.sh — firewall / connectivity validator for the CI ↔ CD/RO ↔ AAP ↔
# Vault zero-trust integration. Turns the firewall matrix
# (vault-integrations/00-architecture-overview.md §4) into a runnable check.
#
# WHY THIS EXISTS
#   Every flow in that matrix crosses a firewall zone and must be explicitly
#   opened. When a flow is closed, logins fail with confusing "signature /
#   validation" errors that look like config problems. This script proves the
#   path first, and — importantly — tells a firewall DROP apart from a service
#   that simply is not listening.
#
# DEPENDENCIES: bash 3.2+. That is the ONLY hard requirement — `timeout` is used
#   when present (coreutils `timeout`/`gtimeout`) but a pure-bash watchdog takes
#   over when it is not, so this runs on a stripped host.
#   Optional, degrade to SKIP with a reason if absent:
#     openssl  -> TLS handshake + certificate reporting
#     curl / wget -> HTTP check (falls back to a raw request over /dev/tcp for
#                    plain HTTP, so http checks usually work with neither)
#     getent / dscacheutil / nslookup / host -> DNS check
#   NO python, NO jq, NO third-party binaries, nothing to install on any host.
#
# NOTE ON `set -e`: deliberately NOT used. Nearly every probe here is expected
#   to exit non-zero (that is the finding, not an error), so errexit would abort
#   the run on the first closed port. Failures are handled explicitly instead.
#
# Usage:  conn_check.sh --help
# ---------------------------------------------------------------------------
set -u

VERSION="1.0.0"
PROG="${0##*/}"

# ---------------------------------------------------------------------------
# Defaults / globals
# ---------------------------------------------------------------------------
CATALOG=""
FILTER_APPS=""
FILTER_ENVS=""
HOP_NAME=""
TIMEOUT=5
INSECURE="no"
CAFILE=""
FORMAT="text"
JUNIT_FILE=""
LIST_ONLY="no"
QUIET="no"
SSH_OPTS=""
INLINE_SPECS=""          # newline-separated expanded specs (from --inline)
SOURCE_LABEL=""

HAVE_DEVTCP="unknown"
TIMEOUT_CMD=""
RESULTS=""             # newline-separated: app|host|port|check|status|ms|detail
N_PASS=0; N_FAIL=0; N_SKIP=0

usage() {
  cat <<EOF
$PROG $VERSION — firewall / connectivity validator (shell only, no dependencies)

USAGE
  $PROG [options]

TARGET SELECTION
  -f, --file FILE       target catalog (default: targets.conf beside this script)
  -a, --app CSV         only these applications (e.g. vault,ci)
  -e, --env CSV         only these environments (e.g. prod)
  -H, --hop NAME|all    SSH to the hop's via-host and run the checks FROM there
      --inline SPEC     check one expanded target; repeatable. Bypasses the
                        catalog entirely. Used internally for hop mode.
                        SPEC = app|host|port|checks|http_path|expect_status|env|notes

BEHAVIOUR
  -t, --timeout SEC     per-check timeout (default $TIMEOUT)
  -k, --insecure        do not verify TLS certificates
      --cafile FILE     private CA bundle for TLS verification
      --ssh-opts STR    extra ssh arguments for hop mode, e.g. "-i \$KEYFILE"

OUTPUT
  -l, --list            print the expanded target list and exit (runs nothing)
      --format text|tsv output format (default text)
      --junit FILE      also write JUnit XML (for CI test reporting)
  -q, --quiet           only print failures and the summary
  -h, --help            this text
  -V, --version         print version

EXIT CODES
  0  every check passed          1  one or more checks failed
  2  usage or catalog error      3  hop/ssh could not be established

EXAMPLES
  $PROG                                   # every target in the catalog
  $PROG --app vault,ci --env prod         # a subset
  $PROG --list                            # what would be checked
  $PROG --hop flow1-vault-to-ci           # run the checks from a Vault node
  $PROG --hop all --ssh-opts "-i ~/.ssh/id_conncheck"
EOF
}

die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }
warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Small helpers (bash 3.2 safe — no associative arrays, no mapfile)
# ---------------------------------------------------------------------------

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# csv_has <csv> <needle> -> 0 if needle is one of the comma-separated items
csv_has() {
  local csv="$1" needle="$2" item oldIFS="$IFS"
  [ -z "$csv" ] && return 1
  IFS=','
  for item in $csv; do
    [ "$(trim "$item")" = "$needle" ] && { IFS="$oldIFS"; return 0; }
  done
  IFS="$oldIFS"
  return 1
}

# Millisecond clock. EPOCHREALTIME is bash 5+; fall back to whole seconds.
now_ms() {
  local e sec usec n
  if [ -n "${EPOCHREALTIME:-}" ]; then          # bash 5+
    e="${EPOCHREALTIME/,/.}"                    # some locales use a comma
    sec="${e%%.*}"; usec="${e#*.}"
    printf '%s' $(( sec * 1000 + 10#${usec:0:3} ))
    return
  fi
  n=$(date +%s%N 2>/dev/null)                   # GNU date (Linux) — nanoseconds
  case "$n" in
    ''|*[!0-9]*) printf '%s' $(( $(date +%s) * 1000 )) ;;   # BSD date: seconds only
    *)           printf '%s' $(( n / 1000000 )) ;;
  esac
}

# run_timeout SECS CMD... — bounded execution, returning 124 on timeout exactly
# as coreutils `timeout` does. Uses `timeout`/`gtimeout` when present; otherwise
# a pure-bash watchdog, so bash itself is the ONLY hard dependency.
run_timeout() {
  local secs="$1"; shift
  local pid wd rc=0

  if [ -n "$TIMEOUT_CMD" ]; then
    "$TIMEOUT_CMD" "$secs" "$@"
    return $?
  fi

  "$@" &
  pid=$!
  { sleep "$secs"; kill -TERM "$pid"; } >/dev/null 2>&1 &
  wd=$!
  wait "$pid" 2>/dev/null || rc=$?
  kill -TERM "$wd" >/dev/null 2>&1
  wait "$wd" >/dev/null 2>&1 || true
  # 143 = 128 + SIGTERM: the watchdog fired.
  [ "$rc" -eq 143 ] && rc=124
  return "$rc"
}

# Does this bash have /dev/tcp? Probe a normally-closed port and read the error:
# "Connection refused" means the feature works; "No such file" means it is off.
detect_devtcp() {
  local err
  # The probe runs in its own subshell, so there is no fd to clean up here.
  # (Never write `exec 3<&- 2>/dev/null` in the main shell: an `exec` with no
  # command applies its redirections PERMANENTLY, which would silently discard
  # every error message the script produces from that point on.)
  err=$( (exec 3<>/dev/tcp/127.0.0.1/9) 2>&1 ) || true
  case "$err" in
    *"o such file"*|*"ot supported"*) return 1 ;;
    *) return 0 ;;
  esac
}

script_dir() {
  local src="$0" dir
  case "$src" in
    bash|sh|-*|"") return 1 ;;    # streamed over stdin (hop mode) — no path
  esac
  dir=$(cd "$(dirname "$src")" 2>/dev/null && pwd) || return 1
  printf '%s' "$dir"
}

hostname_short() {
  if have hostname; then hostname -s 2>/dev/null || hostname 2>/dev/null
  else printf '%s' "${HOSTNAME:-unknown}"
  fi
}

# ---------------------------------------------------------------------------
# Catalog parsing
#
#   TARGET|app|hosts|ports|checks|http_path|expect_status|env|owner|notes   (10)
#   HOP|name|user@host[:port]|apps|notes                                     (5)
#
# Emits expanded specs on stdout, one per line, 8 fields:
#   app|host|port|checks|http_path|expect_status|env|notes
# ---------------------------------------------------------------------------
expand_catalog() {
  local file="$1" want_apps="$2" want_envs="$3"
  local line lineno=0 nf tag app hosts ports checks path expect env owner notes
  local h p oldIFS

  [ -r "$file" ] || die "catalog not readable: $file"

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="$(trim "$line")"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in TARGET'|'*) : ;; HOP'|'*) continue ;; *)
      die "$file:$lineno: line must start with TARGET| or HOP| (got: ${line%%|*})" ;;
    esac

    nf=$(printf '%s\n' "$line" | awk -F'|' '{print NF}')
    [ "$nf" -eq 10 ] || die "$file:$lineno: TARGET needs 10 pipe-separated fields, found $nf"

    oldIFS="$IFS"; IFS='|'
    read -r tag app hosts ports checks path expect env owner notes <<EOF
$line
EOF
    IFS="$oldIFS"

    app=$(trim "$app"); hosts=$(trim "$hosts"); ports=$(trim "$ports")
    checks=$(trim "$checks"); path=$(trim "$path"); expect=$(trim "$expect")
    env=$(trim "$env"); notes=$(trim "$notes")
    [ -n "$app" ]   || die "$file:$lineno: empty app name"
    [ -n "$hosts" ] || die "$file:$lineno: empty host list"
    [ -n "$ports" ] || die "$file:$lineno: empty port list"
    [ "$checks" = "-" ] || [ -z "$checks" ] && checks="dns,tcp"

    if [ -n "$want_apps" ] && ! csv_has "$want_apps" "$app"; then continue; fi
    if [ -n "$want_envs" ] && ! csv_has "$want_envs" "$env"; then continue; fi

    # hosts x ports cartesian product
    oldIFS="$IFS"; IFS=','
    for h in $hosts; do
      h=$(trim "$h"); [ -n "$h" ] || continue
      for p in $ports; do
        p=$(trim "$p"); [ -n "$p" ] || continue
        case "$p" in *[!0-9]*) IFS="$oldIFS"; die "$file:$lineno: bad port '$p'" ;; esac
        printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
          "$app" "$h" "$p" "$checks" "$path" "$expect" "$env" "$notes"
      done
    done
    IFS="$oldIFS"
  done < "$file"
}

# hop_row <file> <name> -> prints "ssh_target|apps|notes" for a HOP row
hop_row() {
  local file="$1" want="$2" line lineno=0 nf tag name sshtarget apps notes oldIFS
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="$(trim "$line")"
    case "$line" in HOP'|'*) : ;; *) continue ;; esac
    nf=$(printf '%s\n' "$line" | awk -F'|' '{print NF}')
    [ "$nf" -eq 5 ] || die "$file:$lineno: HOP needs 5 pipe-separated fields, found $nf"
    oldIFS="$IFS"; IFS='|'
    read -r tag name sshtarget apps notes <<EOF
$line
EOF
    IFS="$oldIFS"
    name=$(trim "$name")
    if [ "$want" = "all" ] || [ "$want" = "$name" ]; then
      printf '%s|%s|%s|%s\n' "$name" "$(trim "$sshtarget")" "$(trim "$apps")" "$(trim "$notes")"
    fi
  done < "$file"
}

# ---------------------------------------------------------------------------
# Individual checks. Each prints a detail string and returns:
#   0 pass | 1 fail | 2 timeout | 3 skipped (tool unavailable)
# ---------------------------------------------------------------------------

# is_ip_literal <host> -> 0 when it is already an address, no resolution needed
is_ip_literal() {
  case "$1" in
    *:*)       return 0 ;;          # IPv6
    *[!0-9.]*) return 1 ;;
    *)         return 0 ;;          # IPv4
  esac
}

# resolve_addrs <host> -> space-separated addresses, empty if it does not resolve.
# Returns 3 when no resolver tool exists at all.
resolve_addrs() {
  local host="$1" out=""
  if have getent; then
    out=$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  elif have dscacheutil; then
    out=$(dscacheutil -q host -a name "$host" 2>/dev/null \
          | awk '/^ip(v6)?_address:/ {print $2}' | sort -u | tr '\n' ' ')
  elif have nslookup; then
    out=$(nslookup "$host" 2>/dev/null | awk '/^Address: /{print $2}' | sort -u | tr '\n' ' ')
  elif have host; then
    out=$(host "$host" 2>/dev/null | awk '/has address/{print $NF}' | sort -u | tr '\n' ' ')
  else
    return 3
  fi
  printf '%s' "$(trim "$out")"
  return 0
}

# Prefer an IPv4 address — firewall rules are usually written against IPv4, and
# a host whose AAAA answers first would otherwise be probed over a path the
# firewall team never opened.
first_ipv4() {
  local a
  for a in $1; do case "$a" in *:*) ;; *) printf '%s' "$a"; return 0 ;; esac; done
  for a in $1; do printf '%s' "$a"; return 0; done
  return 1
}

check_dns() {
  local host="$1" out="" rc=0
  if is_ip_literal "$host"; then
    case "$host" in *:*) printf 'literal IPv6' ;; *) printf 'literal IPv4' ;; esac
    return 0
  fi
  out=$(resolve_addrs "$host") || rc=$?
  [ "$rc" -eq 3 ] && { printf 'no resolver tool (getent/dscacheutil/nslookup/host)'; return 3; }
  if [ -z "$out" ]; then printf 'NXDOMAIN / no address'; return 1; fi
  printf '%s' "$out"
  return 0
}

check_tcp() {
  local host="$1" port="$2" rc=0 err="" addrs="" target="$host" via=""

  # Connect to a resolved address rather than the name. Two reasons:
  #   1. It reports WHICH address is unreachable when a name has several.
  #   2. Some bash builds (notably macOS's bash 3.2) are killed outright when
  #      /dev/tcp has to resolve a hostname; an IP literal is always safe.
  if ! is_ip_literal "$host"; then
    addrs=$(resolve_addrs "$host") || addrs=""
    if [ -n "$addrs" ]; then
      target=$(first_ipv4 "$addrs")
      [ "$target" = "$host" ] || via=" (via $target)"
    fi
  fi

  if [ "$HAVE_DEVTCP" = "yes" ]; then
    err=$(run_timeout "$TIMEOUT" bash -c "exec 3<>/dev/tcp/$target/$port" 2>&1) || rc=$?
  elif have nc; then
    err=$(run_timeout "$TIMEOUT" nc -z -w "$TIMEOUT" "$target" "$port" 2>&1) || rc=$?
  else
    printf 'no /dev/tcp and no nc'; return 3
  fi

  if [ "$rc" -eq 0 ]; then printf 'open%s' "$via"; return 0; fi
  if [ "$rc" -eq 124 ]; then
    printf 'no response in %ss%s — consistent with a firewall DROP' "$TIMEOUT" "$via"; return 2
  fi

  # rc >= 128 means the probe process was killed by a signal — it never reached a
  # verdict. Reporting that as a closed port would send someone chasing a
  # firewall rule for a path that may be perfectly open, so retry with nc and
  # otherwise say plainly that the result is inconclusive.
  if [ "$rc" -ge 128 ]; then
    if have nc; then
      rc=0
      err=$(run_timeout "$TIMEOUT" nc -z -w "$TIMEOUT" "$target" "$port" 2>&1) || rc=$?
      if [ "$rc" -eq 0 ]; then printf 'open%s (via nc)' "$via"; return 0; fi
      if [ "$rc" -eq 124 ]; then
        printf 'no response in %ss%s — consistent with a firewall DROP' "$TIMEOUT" "$via"; return 2
      fi
    else
      printf 'INCONCLUSIVE — probe killed by signal %s%s; install nc or check bash /dev/tcp support' \
        "$((rc - 128))" "$via"
      return 3
    fi
  fi

  case "$err" in
    *[Rr]efused*) printf 'connection refused%s — path is OPEN, nothing listening' "$via"; return 1 ;;
    *nreachable*) printf 'network unreachable%s — routing, not filtering' "$via"; return 1 ;;
    *) printf '%s' "${err:-connect failed (rc=$rc)}$via"; return 1 ;;
  esac
}

check_tls() {
  local host="$1" port="$2" cert="" subj="" enddate="" vopts="" out="" rc=0
  have openssl || { printf 'openssl not installed'; return 3; }

  if [ "$INSECURE" = "yes" ]; then
    vopts=""
  else
    vopts="-verify_return_error -verify 5"
    [ -n "$CAFILE" ] && vopts="$vopts -CAfile $CAFILE"
  fi

  # shellcheck disable=SC2086
  out=$(printf '' | run_timeout "$TIMEOUT" openssl s_client -connect "$host:$port" \
        -servername "$host" $vopts 2>&1) || rc=$?

  if [ "$rc" -eq 124 ]; then printf 'TLS handshake timed out'; return 2; fi

  cert=$(printf '%s\n' "$out" | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p')
  if [ -z "$cert" ]; then
    printf '%s' "$(printf '%s\n' "$out" | grep -iE 'verify error|alert|failure|error' | head -1)"
    [ "$rc" -eq 0 ] && printf 'no certificate returned'
    return 1
  fi

  subj=$(printf '%s\n' "$cert" | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject= *//')
  enddate=$(printf '%s\n' "$cert" | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
  if ! printf '%s\n' "$cert" | openssl x509 -noout -checkend 604800 >/dev/null 2>&1; then
    enddate="$enddate  ** EXPIRES WITHIN 7 DAYS **"
  fi

  if [ "$rc" -ne 0 ]; then
    printf 'chain not verified (%s); subject=%s' \
      "$(printf '%s\n' "$out" | grep -i 'verify error' | head -1 | sed 's/.*:num=[0-9]*://')" "$subj"
    return 1
  fi
  printf 'subject=%s; notAfter=%s' "${subj:-?}" "${enddate:-?}"
  return 0
}

check_http() {
  local host="$1" port="$2" path="$3" expect="$4" checks="$5"
  local scheme code url rc=0 tlsarg=""

  [ -z "$path" ] || [ "$path" = "-" ] && path="/"

  if csv_has "$checks" tls; then scheme="https"
  else
    case "$port" in 443|8443) scheme="https" ;; *) scheme="http" ;; esac
  fi
  url="$scheme://$host:$port$path"

  if have curl; then
    if [ "$scheme" = "https" ]; then
      [ "$INSECURE" = "yes" ] && tlsarg="-k"
      [ -n "$CAFILE" ] && [ "$INSECURE" != "yes" ] && tlsarg="--cacert $CAFILE"
    fi
    # shellcheck disable=SC2086
    code=$(run_timeout "$TIMEOUT" curl -sS -o /dev/null -w '%{http_code}' \
           --max-time "$TIMEOUT" $tlsarg "$url" 2>/dev/null) || rc=$?
  elif have wget; then
    if [ "$scheme" = "https" ] && [ "$INSECURE" = "yes" ]; then tlsarg="--no-check-certificate"; fi
    # shellcheck disable=SC2086
    code=$(run_timeout "$TIMEOUT" wget -q -S --spider $tlsarg "$url" 2>&1 \
           | awk '/^ *HTTP\//{c=$2} END{print c}') || rc=$?
  elif [ "$scheme" = "http" ] && [ "$HAVE_DEVTCP" = "yes" ]; then
    code=$(http_via_devtcp "$host" "$port" "$path") || rc=$?
  else
    printf 'no curl/wget (and %s cannot be done over raw /dev/tcp)' "$scheme"; return 3
  fi

  if [ "$rc" -eq 124 ]; then printf 'HTTP request timed out (%s)' "$url"; return 2; fi
  if [ -z "$code" ] || [ "$code" = "000" ]; then
    printf 'no HTTP response from %s (rc=%s)' "$url" "$rc"; return 1
  fi

  if [ -z "$expect" ] || [ "$expect" = "-" ]; then
    if [ "$code" -ge 200 ] && [ "$code" -lt 400 ]; then
      printf 'HTTP %s (%s)' "$code" "$path"; return 0
    fi
    printf 'HTTP %s — expected 2xx/3xx (%s)' "$code" "$path"; return 1
  fi

  if csv_has "$expect" "$code"; then
    printf 'HTTP %s (%s)' "$code" "$path"; return 0
  fi
  printf 'HTTP %s — expected one of [%s] (%s)' "$code" "$expect" "$path"
  return 1
}

# Raw HTTP/1.1 request over bash's /dev/tcp — no curl, no wget, no binary.
http_via_devtcp() {
  local host="$1" port="$2" path="$3" statusline=""
  # Runs inside a command substitution (its own subshell), so the fd and the
  # stderr redirection below cannot leak into the rest of the script.
  exec 3<>"/dev/tcp/$host/$port" 2>/dev/null || return 1
  printf 'GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: conn_check/%s\r\nConnection: close\r\n\r\n' \
    "$path" "$host" "$VERSION" >&3
  IFS= read -r -t "$TIMEOUT" statusline <&3 || true
  exec 3<&-
  exec 3>&-
  printf '%s' "$statusline" | awk '{print $2}'
}

# ---------------------------------------------------------------------------
# Result recording + rendering
# ---------------------------------------------------------------------------

record() {
  local app="$1" host="$2" port="$3" check="$4" status="$5" ms="$6" detail="$7"
  detail=$(printf '%s' "$detail" | tr '|\n\t' '   ')
  RESULTS="${RESULTS}${app}|${host}|${port}|${check}|${status}|${ms}|${detail}
"
  case "$status" in
    PASS) N_PASS=$((N_PASS + 1)) ;;
    SKIP) N_SKIP=$((N_SKIP + 1)) ;;
    *)    N_FAIL=$((N_FAIL + 1)) ;;
  esac
}

run_one_spec() {
  local spec="$1"
  local app host port checks path expect env notes
  local oldIFS="$IFS" detail status t0 t1 rc

  IFS='|'
  read -r app host port checks path expect env notes <<EOF
$spec
EOF
  IFS="$oldIFS"

  local dns_ok="yes" c
  IFS=','
  set -- $checks
  IFS="$oldIFS"

  for c in "$@"; do
    c=$(trim "$c")
    [ -n "$c" ] || continue

    # If DNS failed there is no point probing the other layers.
    if [ "$dns_ok" = "no" ] && [ "$c" != "dns" ]; then
      record "$app" "$host" "$port" "$c" "SKIP" "0" "skipped — name did not resolve"
      continue
    fi

    t0=$(now_ms); rc=0
    case "$c" in
      dns)  detail=$(check_dns  "$host") || rc=$? ;;
      tcp)  detail=$(check_tcp  "$host" "$port") || rc=$? ;;
      tls)  detail=$(check_tls  "$host" "$port") || rc=$? ;;
      http) detail=$(check_http "$host" "$port" "$path" "$expect" "$checks") || rc=$? ;;
      *)    detail="unknown check type '$c'"; rc=1 ;;
    esac
    t1=$(now_ms)

    case "$rc" in
      0) status="PASS" ;;
      2) status="TIMEOUT" ;;
      3) status="SKIP" ;;
      *) status="FAIL" ;;
    esac
    case "$detail" in *refused*) [ "$status" = "FAIL" ] && status="REFUSED" ;; esac
    [ "$c" = "dns" ] && [ "$status" != "PASS" ] && dns_ok="no"

    record "$app" "$host" "$port" "$c" "$status" "$((t1 - t0))" "$detail"
  done
}

render() {
  local line app host port check status ms detail oldIFS="$IFS"

  if [ "$FORMAT" = "tsv" ]; then
    printf 'app\tsource\thost\tport\tcheck\tstatus\tms\tdetail\n'
  else
    [ "$QUIET" = "yes" ] || printf '%-12s %-34s %-6s %-5s %-8s %6s  %s\n' \
      APP TARGET PORT CHECK RESULT MS DETAIL
    [ "$QUIET" = "yes" ] || printf '%s\n' \
      "-------------------------------------------------------------------------------------------------------"
  fi

  printf '%s' "$RESULTS" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS='|'
    read -r app host port check status ms detail <<EOF
$line
EOF
    IFS="$oldIFS"
    if [ "$QUIET" = "yes" ] && [ "$status" = "PASS" ]; then continue; fi
    if [ "$FORMAT" = "tsv" ]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$app" "$SOURCE_LABEL" "$host" "$port" "$check" "$status" "$ms" "$detail"
    else
      printf '%-12s %-34s %-6s %-5s %-8s %6s  %s\n' \
        "$app" "$host" "$port" "$check" "$status" "$ms" "$detail"
    fi
  done
}

write_junit() {
  local file="$1" line app host port check status ms detail oldIFS="$IFS"
  local total=$((N_PASS + N_FAIL + N_SKIP))
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuite name="firewall-connectivity" tests="%s" failures="%s" skipped="%s" hostname="%s">\n' \
      "$total" "$N_FAIL" "$N_SKIP" "$(xml_escape "$SOURCE_LABEL")"
    printf '%s' "$RESULTS" | while IFS= read -r line; do
      [ -n "$line" ] || continue
      IFS='|'
      read -r app host port check status ms detail <<EOF
$line
EOF
      IFS="$oldIFS"
      printf '  <testcase classname="%s.%s" name="%s:%s %s" time="%s.%03d">\n' \
        "$(xml_escape "$app")" "$(xml_escape "$SOURCE_LABEL")" \
        "$(xml_escape "$host")" "$port" "$check" "$((ms / 1000))" "$((ms % 1000))"
      case "$status" in
        PASS) : ;;
        SKIP) printf '    <skipped message="%s"/>\n' "$(xml_escape "$detail")" ;;
        *)    printf '    <failure type="%s" message="%s"/>\n' \
                "$status" "$(xml_escape "$detail")" ;;
      esac
      printf '  </testcase>\n'
    done
    printf '</testsuite>\n'
  } > "$file"
}

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# ---------------------------------------------------------------------------
# Hop mode — stream this script over SSH and run it on the via-host.
# Nothing is written to the remote disk; the remote side needs no catalog.
# ---------------------------------------------------------------------------
run_hop() {
  local hopname="$1" rows row name sshtarget apps notes
  local user host port specs spec args rc overall=0 oldIFS="$IFS"
  local self dir

  dir=$(script_dir) || die "hop mode needs this script as a readable file (got \$0='$0')"
  self="$dir/$PROG"
  [ -r "$self" ] || die "hop mode needs this script as a readable file (looked for $self)"

  rows=$(hop_row "$CATALOG" "$hopname") || exit $?
  [ -n "$rows" ] || die "no HOP row named '$hopname' in $CATALOG"

  # Fed by here-doc, NOT a pipe, so $overall survives the loop.
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS='|'; read -r name sshtarget apps notes <<EOF2
$row
EOF2
    IFS="$oldIFS"

    # user@host[:port]
    case "$sshtarget" in *@*) user="${sshtarget%%@*}"; host="${sshtarget#*@}" ;;
                         *)   user=""; host="$sshtarget" ;; esac
    case "$host" in *:*) port="${host##*:}"; host="${host%%:*}" ;; *) port=22 ;; esac

    specs=$(expand_catalog "$CATALOG" "$apps" "$FILTER_ENVS") || exit $?
    if [ -z "$specs" ]; then
      warn "hop '$name': no targets matched apps='$apps'"
      continue
    fi

    args=""
    while IFS= read -r spec; do
      [ -n "$spec" ] || continue
      args="$args --inline $(quote "$spec")"
    done <<EOF2
$specs
EOF2
    args="$args --timeout $TIMEOUT --format $FORMAT"
    [ "$INSECURE" = "yes" ] && args="$args --insecure"
    [ -n "$CAFILE" ]        && args="$args --cafile $(quote "$CAFILE")"
    [ "$QUIET" = "yes" ]    && args="$args --quiet"

    printf '\n=== hop: %s — checks run FROM %s ===\n' "$name" "${user:+$user@}$host"
    [ -n "$notes" ] && [ "$notes" != "-" ] && printf '    %s\n' "$notes"

    rc=0
    # The script is piped in on stdin and never touches the remote disk.
    # shellcheck disable=SC2086
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        -p "$port" $SSH_OPTS "${user:+$user@}$host" "bash -s -- $args" < "$self" || rc=$?

    if [ "$rc" -eq 255 ]; then
      warn "hop '$name': SSH to ${user:+$user@}$host:$port failed — this flow could NOT be tested"
      [ "$overall" -lt 3 ] && overall=3
    elif [ "$rc" -ne 0 ]; then
      overall=1
    fi
  done <<EOF2
$rows
EOF2

  return "$overall"
}

# POSIX-safe single-quoting (bash 3.2 has no printf %q on all builds)
quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--file)     CATALOG="${2:-}"; shift 2 ;;
    -a|--app)      FILTER_APPS="${2:-}"; shift 2 ;;
    -e|--env)      FILTER_ENVS="${2:-}"; shift 2 ;;
    -H|--hop)      HOP_NAME="${2:-}"; shift 2 ;;
    --inline)      INLINE_SPECS="${INLINE_SPECS}${2:-}
"; shift 2 ;;
    -t|--timeout)  TIMEOUT="${2:-}"; shift 2 ;;
    -k|--insecure) INSECURE="yes"; shift ;;
    --cafile)      CAFILE="${2:-}"; shift 2 ;;
    --ssh-opts)    SSH_OPTS="${2:-}"; shift 2 ;;
    -l|--list)     LIST_ONLY="yes"; shift ;;
    --format)      FORMAT="${2:-}"; shift 2 ;;
    --junit)       JUNIT_FILE="${2:-}"; shift 2 ;;
    -q|--quiet)    QUIET="yes"; shift ;;
    -h|--help)     usage; exit 0 ;;
    -V|--version)  printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
    --)            shift; break ;;
    *)             die "unknown option '$1' (try --help)" ;;
  esac
done

case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be an integer (got '$TIMEOUT')" ;; esac
case "$FORMAT" in text|tsv) : ;; *) die "--format must be text or tsv (got '$FORMAT')" ;; esac
if   have timeout;  then TIMEOUT_CMD="timeout"
elif have gtimeout; then TIMEOUT_CMD="gtimeout"    # coreutils on macOS/BSD
else TIMEOUT_CMD=""                                # pure-bash watchdog fallback
fi

if detect_devtcp; then HAVE_DEVTCP="yes"; else HAVE_DEVTCP="no"; fi
SOURCE_LABEL="$(hostname_short)"

# Default catalog sits beside the script (not available when streamed over SSH,
# but --inline mode never needs it).
if [ -z "$CATALOG" ] && [ -z "$INLINE_SPECS" ]; then
  _dir=$(script_dir) || die "cannot locate targets.conf — pass --file explicitly"
  CATALOG="$_dir/targets.conf"
fi

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ -n "$HOP_NAME" ]; then
  [ -n "$INLINE_SPECS" ] && die "--hop and --inline are mutually exclusive"
  run_hop "$HOP_NAME"
  exit $?
fi

if [ -n "$INLINE_SPECS" ]; then
  SPECS="$INLINE_SPECS"
else
  # `die` inside the subshell exits it with 2 — propagate rather than silently
  # continuing with an empty target list.
  SPECS=$(expand_catalog "$CATALOG" "$FILTER_APPS" "$FILTER_ENVS") || exit $?
fi

if [ -z "$(trim "$SPECS")" ]; then
  warn "no targets matched (apps='$FILTER_APPS' envs='$FILTER_ENVS')"
  exit 0
fi

if [ "$LIST_ONLY" = "yes" ]; then
  # $SPECS has no trailing newline (command substitution strips it), so print it
  # with one appended — a `while read` loop would silently drop the last row.
  printf '%s\n' "$SPECS"
  exit 0
fi

# No banner in tsv mode — that output is meant to be parsed.
[ "$QUIET" = "yes" ] || [ "$FORMAT" = "tsv" ] || printf 'conn_check %s — running from %s at %s\n\n' \
  "$VERSION" "$SOURCE_LABEL" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

# The check loop must run in THIS shell (not a subshell) so counters survive —
# hence the here-doc feed rather than a pipe.
while IFS= read -r SPEC; do
  [ -n "$SPEC" ] || continue
  run_one_spec "$SPEC"
done <<EOF
$SPECS
EOF

render
[ -n "$JUNIT_FILE" ] && write_junit "$JUNIT_FILE"

[ "$FORMAT" = "tsv" ] || printf '\nSummary (from %s): %s checks — %s pass, %s fail, %s skip\n' \
  "$SOURCE_LABEL" "$((N_PASS + N_FAIL + N_SKIP))" "$N_PASS" "$N_FAIL" "$N_SKIP"

[ "$N_FAIL" -gt 0 ] && exit 1
exit 0
