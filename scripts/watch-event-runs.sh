#!/bin/bash
# Waits for the next problem-triggered (non-manual) run of a workflow to finish,
# then prints the state of each task. Polls once a minute.
#
# Usage: scripts/watch-event-runs.sh <workflow-id> [dtctl-context] [max-minutes]
set -euo pipefail

WF="${1:?workflow id required}"
if [ -n "${2:-}" ]; then export DTCTL_CONTEXT="$2"; fi
MAX="${3:-70}"
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "Watching workflow $WF for event-triggered runs started after $SINCE"
for _ in $(seq 1 "$MAX"); do
  run=$(dtctl get workflow-executions --limit 0 --started-since "$SINCE" -o json --plain --no-agent 2>/dev/null \
    | python3 -c '
import json, sys
wf = sys.argv[1]
d = json.load(sys.stdin)
d = d.get("result", d) if isinstance(d, dict) else d
done = [r for r in d
        if r.get("workflow") == wf
        and r.get("triggerType") != "Manual"
        and r.get("state") not in ("RUNNING", "WAITING", "IDLE")]
print(done[0]["id"] if done else "")
' "$WF")
  if [ -n "$run" ]; then
    echo "Run $run finished:"
    dtctl logs workflow-execution "$run" --plain
    exit 0
  fi
  sleep 60
done
echo "No event-triggered run finished within $MAX minutes." >&2
exit 1
