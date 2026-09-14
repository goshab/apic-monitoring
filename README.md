# apic-monitoring

Health-check script for IBM APIC (API Connect) Kubernetes resources. Verifies
that a set of resources are in `Running` phase, that another set report a
`Ready` condition, reports whether their recent Kubernetes events contain
any `Warning`s, and checks every cert-manager `Certificate` in the
namespace for upcoming or past expiration.

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
- Exit code `4` — WARNING: no failures, but at least one certificate expires
  within `CERT_EXPIRATION_INTERVAL` days.
- Exit code `8` — ERROR: a usage/dependency error, or at least one check
  failed (including an already-expired or unparseable certificate).
- Human-readable status lines are printed to stdout for each checked
  resource; errors go to stderr.

### Config file (`apic-env-template.conf`)

| Variable            | Required | Description                                                                 |
|---------------------|----------|-------------------------------------------------------------------------------|
| `NAMESPACE`          | yes      | Kubernetes namespace to query.                                              |
| `REQUEST_TIMEOUT`    | no       | `--request-timeout` passed to every `kubectl` call (default: `10s`).       |
| `RUNNING_RESOURCES`  | no       | Array of `kind/name` entries whose `.status.phase` must be `Running`.      |
| `READY_RESOURCES`    | no       | Array of `kind/name` entries whose `status.conditions[type=="Ready"]` must be `True`. |
| `EVENTS_RESOURCES`   | no       | Array of `kind/name` entries whose Kubernetes events must contain no `Warning`. |
| `CERT_EXPIRATION_INTERVAL` | no      | Days before expiration at which a certificate triggers a `WARNING` (default: `30`; an `INFO` line is printed when it falls back to the default). |

## Logic

For each entry, `<params-file>` is `source`d, then:

1. **Running check** (`RUNNING_RESOURCES`) — for each `kind/name`:
   - Fetches `.status.phase` via `kubectl get <kind> <name> -o jsonpath`.
   - Reports `Running` if the phase is `Running`; otherwise reports
     `Not Running` (with the phase, if any) and marks the overall run failed.
   - If the resource can't be fetched (missing/unreachable), reports
     `unavailable or does not exist` and marks the run failed.

2. **Ready check** (`READY_RESOURCES`) — for each `kind/name`:
   - Fetches the `status` of the `status.conditions[]` entry with
     `type == "Ready"` via `kubectl get <kind> <name> -o jsonpath`. This is
     the standard Kubernetes readiness convention (used by `Pod`s,
     cert-manager `Certificate`s, etc.), distinct from `.status.phase`.
   - Reports `Ready` if that status is `True`; otherwise reports
     `Not Ready` (with the status, if any) and marks the overall run failed.
   - If the resource can't be fetched (missing/unreachable), reports
     `unavailable or does not exist` and marks the run failed.

3. **Events check** (`EVENTS_RESOURCES`) — for each `kind/name`:
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

4. **Certificate expiration check** — unlike the checks above, this one
   isn't driven by a configured list; it fetches every cert-manager
   `Certificate` in `NAMESPACE` via `kubectl get certificates -o json` and,
   for each, reads `status.notAfter`:
   - **Expired** (`notAfter` in the past) — reports `ERROR, expired on
     <date>` and marks the overall run failed.
   - **Expiring soon** (`notAfter` within `CERT_EXPIRATION_INTERVAL` days)
     — reports `WARNING, expires in <N>d` but does *not* mark the run
     failed.
   - Otherwise reports `OK, expires on <date>`.
   - A certificate with no `status.notAfter` (not yet issued) or an
     unparseable date is reported and marks the run failed.
   - No certificates found in the namespace is not treated as a failure.

5. All results are printed as they're checked. The script's exit code
   reflects the worst outcome across all sections: `8` if any check failed
   (including an expired/unparseable certificate), else `4` if any
   certificate is merely expiring soon, else `0`. This makes it suitable as
   a probe for external monitoring/alerting tooling.
