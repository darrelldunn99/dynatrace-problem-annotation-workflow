#!/bin/bash
# Lists the workflow actions the Dynatrace Intelligence app provides on a tenant.
# Use it to confirm which agentic AI action your tenant has before importing the workflow.
#
# Usage: scripts/list-ai-actions.sh [dtctl-context]
set -euo pipefail

if [ -n "${1:-}" ]; then export DTCTL_CONTEXT="$1"; fi

echo "Context: $(dtctl config current-context --plain)"
echo
echo "Davis / Intelligence apps installed:"
dtctl get apps --limit 0 -o json --plain --no-agent \
  | python3 -c '
import json, sys
apps = json.load(sys.stdin)
apps = apps.get("result", apps) if isinstance(apps, dict) else apps
for a in apps:
    if "davis" in a["id"] or "intelligence" in a["id"]:
        print("  %-45s %s" % (a["id"], a.get("version", "")))
'
echo
echo "Actions in dynatrace.davis.workflow.actions:"
dtctl describe app dynatrace.davis.workflow.actions -o json --plain --no-agent \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
d = d.get("result", d)
for a in d["manifest"].get("actions", []):
    print("  dynatrace.davis.workflow.actions:%-22s %s" % (a["name"], a.get("title", "")))
'
