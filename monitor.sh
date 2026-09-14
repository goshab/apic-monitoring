#!/usr/bin/env bash
set -uo pipefail

# Prints a message in a standard log format:
# [date-time] [log-level] [component] [message]
# log-level: INFO / WARNING / ERROR. component: the function log() was
# called from (or "main" for top-level, pre-check calls). ERROR lines go to
# stderr, everything else to stdout.
log() {
  local level="$1"
  shift
  local component="${FUNCNAME[1]:-main}"
  local line
  line=$(printf '[%s] [%s] [%s] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$component" "$*")
  if [[ "$level" == "ERROR" ]]; then
    echo "$line" >&2
  else
    echo "$line"
  fi
}

if [[ $# -ne 1 ]]; then
  log ERROR "Usage: $0 <params-file>"
  exit 8
fi

PARAMS_FILE="$1"

if [[ ! -f "$PARAMS_FILE" ]]; then
  log ERROR "parameter file not found: $PARAMS_FILE"
  exit 8
fi

command -v kubectl >/dev/null 2>&1 || {
  log ERROR "kubectl is required"
  exit 8
}

command -v jq >/dev/null 2>&1 || {
  log ERROR "jq is required"
  exit 8
}

source "$PARAMS_FILE"

if [[ -z "${NAMESPACE:-}" ]]; then
  log ERROR "NAMESPACE is not defined in $PARAMS_FILE"
  exit 8
else
  log INFO "NAMESPACE loaded from configuration: $NAMESPACE"
fi

if [[ -z "${CERT_EXPIRATION_INTERVAL:-}" ]]; then
  log INFO "CERT_EXPIRATION_INTERVAL is not defined in $PARAMS_FILE, defaulting to 30"
  CERT_EXPIRATION_INTERVAL=30
else
  log INFO "CERT_EXPIRATION_INTERVAL loaded from configuration: $CERT_EXPIRATION_INTERVAL"
fi

RUNNING_RESOURCES=("${RUNNING_RESOURCES[@]:-}")
READY_RESOURCES=("${READY_RESOURCES[@]:-}")
EVENTS_RESOURCES=("${EVENTS_RESOURCES[@]:-}")

# How long any single kubectl call may block before giving up - read from
# the params file so a slow/unreachable cluster fails fast instead of
# hanging the whole monitor run. Defaults to 10s if the conf file (e.g. an
# older one written for monitor.sh v1) doesn't define it.
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-10s}"

all_checks_passed=true
has_warning=false

# Converts an RFC3339 timestamp (as reported in a Certificate's
# status.notAfter, always UTC/"Z") to epoch seconds. Tries GNU date first,
# falls back to BSD date (macOS) - the two accept incompatible flags for
# this - and prints nothing (exit 1) if neither can parse it. -u is required
# on the BSD path: unlike GNU date, BSD date -j -f treats a trailing "Z" as
# a literal format character rather than a UTC marker, so without -u it
# silently parses the timestamp as local time on non-UTC hosts.
to_epoch() {
  local ts="$1" epoch
  epoch=$(date -d "$ts" +%s 2>/dev/null) && { echo "$epoch"; return 0; }
  epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null) && { echo "$epoch"; return 0; }
  return 1
}

check_running_resources() {
  log INFO "Checking for RUNNING resources"
  for resource in "${RUNNING_RESOURCES[@]}"; do
    [[ -z "$resource" ]] && continue

    if [[ "$resource" != */* ]]; then
      log ERROR "$resource: invalid format; expected kind/name"
      all_checks_passed=false
      continue
    fi

    kind="${resource%%/*}"
    name="${resource#*/}"

    # -o jsonpath asks the server for just this one field instead of the
    # whole object, so there's nothing to hand to jq for this check at all.
    phase=$(kubectl get "$kind" "$name" \
      -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' \
      --request-timeout="$REQUEST_TIMEOUT" \
      2>/dev/null)

    if [[ $? -ne 0 ]]; then
      log ERROR "$resource: unavailable or does not exist"
      all_checks_passed=false
      continue
    fi

    if [[ "$phase" == "Running" ]]; then
      log INFO "$resource: Running"
    else
      log ERROR "$resource: Not Running${phase:+, status=$phase}"
      all_checks_passed=false
    fi
  done
}

check_ready_resources() {
  log INFO "Checking for READY resources"
  for resource in "${READY_RESOURCES[@]}"; do
    [[ -z "$resource" ]] && continue

    if [[ "$resource" != */* ]]; then
      log ERROR "$resource: invalid format; expected kind/name"
      all_checks_passed=false
      continue
    fi

    kind="${resource%%/*}"
    name="${resource#*/}"

    # Standard Kubernetes convention: readiness is a status.conditions[]
    # entry with type "Ready" (used by Pods, cert-manager Certificates,
    # etc.), so jsonpath filters straight to its status without needing jq.
    ready_status=$(kubectl get "$kind" "$name" \
      -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
      --request-timeout="$REQUEST_TIMEOUT" \
      2>/dev/null)

    if [[ $? -ne 0 ]]; then
      log ERROR "$resource: unavailable or does not exist"
      all_checks_passed=false
      continue
    fi

    if [[ "$ready_status" == "True" ]]; then
      log INFO "$resource: Ready"
    else
      log ERROR "$resource: Not Ready${ready_status:+, status=$ready_status}"
      all_checks_passed=false
    fi
  done
}

check_event_resources() {
  log INFO "Checking for events with WARNING status"
  for resource in "${EVENTS_RESOURCES[@]}"; do
    [[ -z "$resource" ]] && continue

    if [[ "$resource" != */* ]]; then
      log ERROR "$resource: invalid format; expected kind/name"
      all_checks_passed=false
      continue
    fi

    kind="${resource%%/*}"
    name="${resource#*/}"

    # Event objects record involvedObject.kind as the resource's real
    # Kubernetes Kind (e.g. "ManagementCluster"), not whatever short name
    # (e.g. "mgmt") the conf file's kind/name pair uses - resolve it first.
    # This call doubles as the existence check `describe` used to do.
    full_kind=$(kubectl get "$kind" "$name" \
      -n "$NAMESPACE" \
      -o jsonpath='{.kind}' \
      --request-timeout="$REQUEST_TIMEOUT" \
      2>/dev/null)

    if [[ $? -ne 0 || -z "$full_kind" ]]; then
      log ERROR "$resource: unavailable or does not exist"
      all_checks_passed=false
      continue
    fi

    # Query Event objects directly as JSON instead of scraping `kubectl
    # describe`'s free-text output - describe's formatting is for human
    # consumption and isn't a stable API, so parsing it (the v1 approach)
    # is one kubectl version bump away from silently breaking.
    events_json=$(kubectl get events \
      -n "$NAMESPACE" \
      --field-selector "involvedObject.kind=${full_kind},involvedObject.name=${name}" \
      -o json \
      --request-timeout="$REQUEST_TIMEOUT" \
      2>/dev/null)

    if [[ $? -ne 0 ]]; then
      log ERROR "$resource: unable to fetch events"
      all_checks_passed=false
      continue
    fi

    event_result=$(jq -r '
      if ([.items[].type] | any(. == "Warning")) then "WARNING"
      elif (.items | length) > 0 then "NORMAL"
      else "NO_EVENTS"
      end
    ' <<< "$events_json")

    case "$event_result" in
      NORMAL)
        log INFO "$resource: all events are Normal"
        ;;

      NO_EVENTS)
        log INFO "$resource: no events found"
        ;;

      WARNING)
        log WARNING "$resource: contains Warning events"
        all_checks_passed=false
        ;;

      *)
        log ERROR "$resource: unable to parse events"
        all_checks_passed=false
        ;;
    esac

  done
}

check_certificate_expiration() {
  log INFO "Checking certificate expiration (namespace-wide, warn within ${CERT_EXPIRATION_INTERVAL}d)"

  # Unlike the other checks, this one isn't driven by a configured list of
  # resources - it walks every cert-manager Certificate in the namespace.
  certs_json=$(kubectl get certificates \
    -n "$NAMESPACE" \
    -o json \
    --request-timeout="$REQUEST_TIMEOUT" \
    2>/dev/null)

  if [[ $? -ne 0 ]]; then
    log ERROR "unable to fetch certificates in namespace $NAMESPACE"
    all_checks_passed=false
    return
  fi

  if [[ "$(jq '.items | length' <<< "$certs_json")" -eq 0 ]]; then
    log INFO "no certificates found in namespace $NAMESPACE"
    return
  fi

  now_epoch=$(date +%s)
  warning_seconds=$(( CERT_EXPIRATION_INTERVAL * 86400 ))

  while IFS=$'\t' read -r name not_after; do
    [[ -z "$name" ]] && continue

    if [[ -z "$not_after" || "$not_after" == "null" ]]; then
      log ERROR "cert/$name: no expiration date reported (not yet issued?)"
      all_checks_passed=false
      continue
    fi

    if ! exp_epoch=$(to_epoch "$not_after"); then
      log ERROR "cert/$name: unable to parse expiration date '$not_after'"
      all_checks_passed=false
      continue
    fi

    remaining=$(( exp_epoch - now_epoch ))

    if (( remaining < 0 )); then
      log ERROR "cert/$name: expired on $not_after"
      all_checks_passed=false
    elif (( remaining <= warning_seconds )); then
      log WARNING "cert/$name: expires in $(( remaining / 86400 ))d (on $not_after)"
      has_warning=true
    else
      log INFO "cert/$name: expires on $not_after"
    fi
  done < <(jq -r '.items[] | [.metadata.name, .status.notAfter // ""] | @tsv' <<< "$certs_json")
}

check_running_resources
check_ready_resources
check_event_resources
check_certificate_expiration

if [[ "$all_checks_passed" != "true" ]]; then
  log ERROR "Overall status: ERROR (exit 8)"
  exit 8
elif [[ "$has_warning" == "true" ]]; then
  log WARNING "Overall status: WARNING (exit 4)"
  exit 4
else
  log INFO "Overall status: OK (exit 0)"
  exit 0
fi
