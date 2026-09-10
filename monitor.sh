#!/usr/bin/env bash
set -uo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <params-file>" >&2
  exit 8
fi

PARAMS_FILE="$1"

if [[ ! -f "$PARAMS_FILE" ]]; then
  echo "Error: parameter file not found: $PARAMS_FILE" >&2
  exit 8
fi

command -v kubectl >/dev/null 2>&1 || {
  echo "Error: kubectl is required" >&2
  exit 8
}

command -v jq >/dev/null 2>&1 || {
  echo "Error: jq is required" >&2
  exit 8
}

source "$PARAMS_FILE"

if [[ -z "${NAMESPACE:-}" ]]; then
  echo "Error: NAMESPACE is not defined in $PARAMS_FILE" >&2
  exit 8
fi

RUNNING_RESOURCES=("${RUNNING_RESOURCES[@]:-}")
EVENTS_RESOURCES=("${EVENTS_RESOURCES[@]:-}")

# How long any single kubectl call may block before giving up - read from
# the params file so a slow/unreachable cluster fails fast instead of
# hanging the whole monitor run. Defaults to 10s if the conf file (e.g. an
# older one written for monitor.sh v1) doesn't define it.
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-10s}"

all_checks_passed=true

check_running_resources() {
  for resource in "${RUNNING_RESOURCES[@]}"; do
    [[ -z "$resource" ]] && continue

    if [[ "$resource" != */* ]]; then
      echo "$resource: invalid format; expected kind/name"
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
      echo "$resource: unavailable or does not exist"
      all_checks_passed=false
      continue
    fi

    if [[ "$phase" == "Running" ]]; then
      echo "$resource: Running"
    else
      echo "$resource: Not Running${phase:+, status=$phase}"
      all_checks_passed=false
    fi
  done
}

check_event_resources() {
  for resource in "${EVENTS_RESOURCES[@]}"; do
    [[ -z "$resource" ]] && continue

    if [[ "$resource" != */* ]]; then
      echo "$resource: invalid format; expected kind/name"
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
      echo "$resource: unavailable or does not exist"
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
      echo "$resource: unable to fetch events"
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
        echo "$resource: all events are Normal"
        ;;

      NO_EVENTS)
        echo "$resource: no events found"
        ;;

      WARNING)
        echo "$resource: contains Warning events"
        all_checks_passed=false
        ;;

      *)
        echo "$resource: unable to parse events"
        all_checks_passed=false
        ;;
    esac

  done
}

check_running_resources
check_event_resources

if [[ "$all_checks_passed" == "true" ]]; then
  exit 0
else
  exit 8
fi
