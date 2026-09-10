# apic-monitoring

Health-check script for IBM APIC (API Connect) Kubernetes resources. Verifies
that a set of resources are in `Running` phase and reports whether their
recent Kubernetes events contain any `Warning`s.

## Requirements

- `bash`
- `kubectl`, configured with access to the target cluster/namespace
- `jq`

## Usage

```bash
./monitor.sh <params-file>
```

- `<params-file>` is a shell-sourced config file (see [apic-env-template.conf](apic-env-template.conf))
  defining the namespace and which resources to check.
- Exit code `0` — all checks passed.
- Exit code `8` — a usage/dependency error, or at least one check failed.
- Human-readable status lines are printed to stdout for each checked
  resource; errors go to stderr.

### Config file (`apic.conf`)

| Variable            | Required | Description                                                                 |
|---------------------|----------|-------------------------------------------------------------------------------|
| `NAMESPACE`          | yes      | Kubernetes namespace to query.                                              |
| `REQUEST_TIMEOUT`    | no       | `--request-timeout` passed to every `kubectl` call (default: `10s`).       |
| `RUNNING_RESOURCES`  | no       | Array of `kind/name` entries whose `.status.phase` must be `Running`.      |
| `EVENTS_RESOURCES`   | no       | Array of `kind/name` entries whose Kubernetes events must contain no `Warning`. |

## Logic

For each entry, `<params-file>` is `source`d, then:

1. **Running check** (`RUNNING_RESOURCES`) — for each `kind/name`:
   - Fetches `.status.phase` via `kubectl get <kind> <name> -o jsonpath`.
   - Reports `Running` if the phase is `Running`; otherwise reports
     `Not Running` (with the phase, if any) and marks the overall run failed.
   - If the resource can't be fetched (missing/unreachable), reports
     `unavailable or does not exist` and marks the run failed.

2. **Events check** (`EVENTS_RESOURCES`) — for each `kind/name`:
   - Resolves the resource's real Kubernetes `Kind` via
     `kubectl get <kind> <name> -o jsonpath='{.kind}'` (this also serves as
     the existence check, since a short `kind` alias like `gw` may not
     match the `involvedObject.kind` recorded on events, which is the full
     Kind such as `Gateway`).
   - Fetches matching `Event` objects with
     `kubectl get events --field-selector involvedObject.kind=...,involvedObject.name=...`
     as JSON, then classifies them with `jq`:
     - `WARNING` — at least one event has `type == "Warning"` → reported as
       "contains Warning events", marks the run failed.
     - `NORMAL` — events exist, none are `Warning` → reported as
       "all events are Normal".
     - `NO_EVENTS` — no events found → reported as "no events found" (not
       treated as a failure).
   - Malformed `kind/name` entries or failed `kubectl` calls are reported
     and marked as failures.

3. All results are printed as they're checked. The script exits `0` only if
   every check across both sections passed; otherwise it exits `8`, making
   it suitable as a probe for external monitoring/alerting tooling.
