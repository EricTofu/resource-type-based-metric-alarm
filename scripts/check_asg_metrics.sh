#!/usr/bin/env bash
# Checks that every ASG in asg_resources has GroupInServiceInstances metric collection
# enabled. Exits 1 if any ASG is missing the metric.
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
m = re.search(r'aws_region\s*=\s*"([^"]+)"', content)
print(m.group(1) if m else "")
EOF
)

NAMES=$(python3 - "$TFVARS" "asg_resources" "in_service_capacity" <<'EOF'
import re, sys
content = open(sys.argv[1]).read()
list_var, metric = sys.argv[2], sys.argv[3]

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
    nm = re.search(r'name\s*=\s*"([^"]+)"', e)
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
  echo "No asg_resources found in $TFVARS — skipping."
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
