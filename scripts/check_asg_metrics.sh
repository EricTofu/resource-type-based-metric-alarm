#!/usr/bin/env bash
# Checks that every LEGACY ASG in asg_resources has GroupInServiceInstances metric
# collection enabled. Exits 1 if any ASG is missing the metric.
#
# Fleet-mode entries (those with asg_tag_value) are SKIPPED here: their `name` is a
# logical label, not an ASG name, and the real ASG name churns on every
# CodeDeploy blue/green deploy by design. They are covered by
# scripts/check_asg_fleet_metrics.sh, which runs the fleet alarms' own
# AppName-scoped Metrics Insights queries.
#
# Usage: check_asg_metrics.sh --tfvars <path>
# Example: check_asg_metrics.sh --tfvars stacks/projects/billing/dev/terraform.tfvars

set -euo pipefail

TFVARS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tfvars) TFVARS="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$TFVARS" ]]; then
  echo "Usage: $0 --tfvars <path>" >&2
  exit 1
fi

[[ -f "$TFVARS" ]] || { echo "Error: $TFVARS not found." >&2; exit 1; }

REGION=$(python3 - "$TFVARS" <<'EOF'
import re, sys
content = open(sys.argv[1]).read()
# Line comments stripped first so a commented-out aws_region cannot win.
content = re.sub(r'(?m)#.*$|//.*$', '', content)
m = re.search(r'aws_region\s*=\s*"([^"]+)"', content)
print(m.group(1) if m else "")
EOF
)

NAMES=$(python3 - "$TFVARS" "asg_resources" "in_service_capacity" <<'EOF'
import re, sys
content = open(sys.argv[1]).read()
list_var, metric = sys.argv[2], sys.argv[3]

# Strip line comments BEFORE the bracket/brace counting below: both scans are
# plain character counters over raw text, so an unbalanced `{` inside a comment
# truncated the list scan, and a *balanced* commented-out entry was parsed as
# live (this script used to fail on the commented-out "billing-web-asg" in
# terraform.tfvars.example for exactly that reason). No tfvars in this repo puts
# `#` or `//` inside a string literal, which is the only thing this would
# corrupt. HCL `/* */` block comments are not used here and are not handled.
content = re.sub(r'(?m)#.*$|//.*$', '', content)

start = re.search(rf'{list_var}\s*=\s*\[', content)
if not start:
    sys.exit(0)

# Capture the bracketed list body by bracket depth.
i, depth, body = start.end(), 1, []
while i < len(content) and depth > 0:
    c = content[i]
    if c == '[':
        depth += 1
    elif c == ']':
        depth -= 1
        if depth == 0:
            break
    body.append(c)
    i += 1
body = ''.join(body)

# Split body into top-level { ... } object entries.
entries, depth, cur = [], 0, []
for c in body:
    if c == '{':
        depth += 1
        if depth == 1:
            cur = []
            continue
    if c == '}':
        depth -= 1
        if depth == 0:
            entries.append(''.join(cur))
            continue
    if depth >= 1:
        cur.append(c)

for e in entries:
    # Fleet-mode entries are handled by check_asg_fleet_metrics.sh; their name is
    # a logical label, not a live ASG name.
    if re.search(r'\basg_tag_value\s*=\s*"', e):
        continue
    # \b anchors on the whole key: an unanchored 'name' also matches other keys,
    # process_group... and would capture the wrong value.
    nm = re.search(r'\bname\s*=\s*"([^"]+)"', e)
    if not nm:
        continue
    da = re.search(r'disabled_alarms\s*=\s*\[([^\]]*)\]', e)
    disabled = re.findall(r'"([^"]+)"', da.group(1)) if da else []
    if metric in disabled:
        continue
    print(nm.group(1))
EOF
)

if [[ -z "$NAMES" ]]; then
  echo "No legacy asg_resources found in $TFVARS — skipping (fleet entries are checked by check_asg_fleet_metrics.sh)."
  exit 0
fi

[[ -n "$REGION" ]] || { echo "Error: aws_region not found in $TFVARS." >&2; exit 1; }

FAILED=0

while IFS= read -r NAME; do
  ENABLED_METRICS=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$NAME" \
    --region "$REGION" \
    --query "AutoScalingGroups[0].EnabledMetrics[*].Metric" \
    --output text 2>/dev/null || true)

  if [[ "$ENABLED_METRICS" != *"GroupInServiceInstances"* ]]; then
    echo "WARNING: Metric 'GroupInServiceInstances' is not enabled for ASG '$NAME' in $REGION. Enable group metrics collection on the ASG." >&2
    FAILED=1
  else
    echo "OK: GroupInServiceInstances enabled for ASG '$NAME'."
  fi
done <<< "$NAMES"

exit "$FAILED"
