#!/usr/bin/env bash
# Checks that every host in jmx_resources publishes the CWAgent JVM metrics its
# alarms depend on ({InstanceId} rollup, see cwagent/jmx/):
#   heap_used alarm -> jvm.memory.heap.used + jvm.memory.heap.max
#   gc_time  alarm -> jvm.gc.collections.elapsed
# Respects overrides.disabled_alarms per resource. Exits 1 on any missing metric.
#
# Usage: check_jmx_metrics.sh --tfvars <path>
# Example: check_jmx_metrics.sh --tfvars stacks/projects/billing/dev/terraform.tfvars

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

# Extracts resource names from a tfvars list var, skipping entries whose
# disabled_alarms contains the given metric id. Same parser as
# check_ec2_mem_metric.sh.
extract_names() {
python3 - "$TFVARS" "jmx_resources" "$1" <<'EOF'
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
    # \b anchors on the whole key: unanchored 'name' also matches *_name keys.
    nm = re.search(r'\bname\s*=\s*"([^"]+)"', e)
    if not nm:
        continue
    da = re.search(r'disabled_alarms\s*=\s*\[([^\]]*)\]', e)
    disabled = re.findall(r'"([^"]+)"', da.group(1)) if da else []
    if metric in disabled:
        continue
    print(nm.group(1))
EOF
}

NAMES_HEAP=$(extract_names "heap_used")
NAMES_GC=$(extract_names "gc_time")

if [[ -z "$NAMES_HEAP" && -z "$NAMES_GC" ]]; then
  echo "No jmx_resources found in $TFVARS — skipping."
  exit 0
fi

[[ -n "$REGION" ]] || { echo "Error: aws_region not found in $TFVARS." >&2; exit 1; }

FAILED=0

resolve_instance() {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running,stopped" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text \
    --region "$REGION" 2>/dev/null || true
}

check_metric() {
  local NAME="$1" INSTANCE_ID="$2" METRIC="$3"
  local COUNT
  COUNT=$(aws cloudwatch list-metrics \
    --namespace CWAgent \
    --metric-name "$METRIC" \
    --dimensions "Name=InstanceId,Value=$INSTANCE_ID" \
    --region "$REGION" \
    --query "length(Metrics)" \
    --output text 2>/dev/null || echo "0")

  if [[ "$COUNT" == "0" || -z "$COUNT" ]]; then
    echo "WARNING: CWAgent metric '$METRIC' not found for '$NAME' ($INSTANCE_ID) in $REGION. Deploy the JMX agent config (cwagent/jmx/) on the host." >&2
    FAILED=1
  else
    echo "OK: $METRIC present for '$NAME' ($INSTANCE_ID)."
  fi
}

check_host() {
  local NAME="$1"; shift
  local INSTANCE_ID
  INSTANCE_ID=$(resolve_instance "$NAME")
  if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
    echo "WARNING: No running/stopped EC2 instance found with Name tag '$NAME' in $REGION." >&2
    FAILED=1
    return
  fi
  local METRIC
  for METRIC in "$@"; do
    check_metric "$NAME" "$INSTANCE_ID" "$METRIC"
  done
}

if [[ -n "$NAMES_HEAP" ]]; then
  while IFS= read -r NAME; do
    check_host "$NAME" "jvm.memory.heap.used" "jvm.memory.heap.max"
  done <<< "$NAMES_HEAP"
fi

if [[ -n "$NAMES_GC" ]]; then
  while IFS= read -r NAME; do
    check_host "$NAME" "jvm.gc.collections.elapsed"
  done <<< "$NAMES_GC"
fi

exit "$FAILED"
