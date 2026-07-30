#!/usr/bin/env bash
# Checks that every EC2 instance in ec2_resources publishes the CWAgent metrics its
# alarms depend on:
#   memory alarm -> mem_used_percent           at {InstanceId}
#   disk   alarm -> disk_used_percent          at {InstanceId, path=/}
# Both alarms treat missing data as notBreaching, so a host without the agent
# config would sit green forever. Entries opt out per metric via
# overrides.disabled_alarms (["memory"], ["disk"], or both for agentless boxes).
# The disk series comes from the [InstanceId, path] rollup in the
# cwagent/ec2-java/ template; the older cwagent/jmx/ config does not publish it.
# Exits 1 if any expected metric is missing.
#
# Usage: check_ec2_mem_metric.sh --tfvars <path>
# Example: check_ec2_mem_metric.sh --tfvars stacks/projects/billing/dev/terraform.tfvars

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

# Emits one line per entry: name<TAB>check_memory<TAB>check_disk
# check_* is 0 when the metric's alarm id is in overrides.disabled_alarms.
ENTRIES=$(python3 - "$TFVARS" "ec2_resources" <<'EOF'
import re, sys
content = open(sys.argv[1]).read()
list_var = sys.argv[2]

# Strip line comments BEFORE the bracket/brace counting below: both scans are
# plain character counters over raw text, so an unbalanced `{` inside a comment
# truncated the list scan and a *balanced* commented-out entry was parsed as live.
# No tfvars in this repo puts `#` or `//` inside a string literal, which is the
# only thing this would corrupt. HCL `/* */` block comments are not used here and
# are not handled.
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
    # \b anchors on the whole key: unanchored 'name' also matches *_name keys.
    nm = re.search(r'\bname\s*=\s*"([^"]+)"', e)
    if not nm:
        continue
    da = re.search(r'disabled_alarms\s*=\s*\[([^\]]*)\]', e)
    disabled = re.findall(r'"([^"]+)"', da.group(1)) if da else []
    check_memory = 0 if "memory" in disabled else 1
    check_disk = 0 if "disk" in disabled else 1
    if not check_memory and not check_disk:
        continue
    print(f"{nm.group(1)}\t{check_memory}\t{check_disk}")
EOF
)

if [[ -z "$ENTRIES" ]]; then
  echo "No ec2_resources found in $TFVARS — skipping."
  exit 0
fi

[[ -n "$REGION" ]] || { echo "Error: aws_region not found in $TFVARS." >&2; exit 1; }

FAILED=0

# check_metric <name> <instance-id> <metric> [extra dimension filters...]
check_metric() {
  local NAME="$1" INSTANCE_ID="$2" METRIC="$3" HINT="$4"; shift 4
  local COUNT
  COUNT=$(aws cloudwatch list-metrics \
    --namespace CWAgent \
    --metric-name "$METRIC" \
    --dimensions "Name=InstanceId,Value=$INSTANCE_ID" "$@" \
    --region "$REGION" \
    --query "length(Metrics)" \
    --output text 2>/dev/null || echo "0")

  if [[ "$COUNT" == "0" || -z "$COUNT" ]]; then
    echo "WARNING: CWAgent metric '$METRIC' not found for instance '$NAME' ($INSTANCE_ID) in $REGION. $HINT" >&2
    FAILED=1
  else
    echo "OK: $METRIC present for '$NAME' ($INSTANCE_ID)."
  fi
}

while IFS=$'\t' read -r NAME CHECK_MEMORY CHECK_DISK; do
  INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=running,stopped" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text \
    --region "$REGION" 2>/dev/null || true)

  if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
    echo "WARNING: No running/stopped EC2 instance found with Name tag '$NAME' in $REGION." >&2
    FAILED=1
    continue
  fi

  if [[ "$CHECK_MEMORY" == "1" ]]; then
    check_metric "$NAME" "$INSTANCE_ID" "mem_used_percent" \
      "Install and configure the CloudWatch Agent."
  fi

  # The disk alarm is pinned to {InstanceId, path=/}, so check that exact
  # dimension pair — the agent must publish the [InstanceId, path] rollup.
  if [[ "$CHECK_DISK" == "1" ]]; then
    check_metric "$NAME" "$INSTANCE_ID" "disk_used_percent" \
      "Deploy the cwagent/ec2-java/ config (disk plugin with resources ['/'] and the [InstanceId, path] rollup)." \
      "Name=path,Value=/"
  fi
done <<< "$ENTRIES"

exit "$FAILED"
