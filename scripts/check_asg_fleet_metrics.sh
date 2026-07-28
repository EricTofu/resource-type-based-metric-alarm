#!/usr/bin/env bash
# Checks fleet-mode asg_resources (entries with app_name) prerequisites by
# running the SAME Metrics Insights queries the fleet alarms use:
#   - running EC2 instances tagged AppName=<v> exist
#   - tag-scoped GroupInServiceCapacity query returns data (proves the
#     CloudWatch "resource tags on telemetry" setting + ASG tag)
#   - (unless cpu disabled) tag-scoped CPUUtilization query returns data
#     (proves tag telemetry for AWS/EC2 — a separate path from AWS/AutoScaling)
#   - CWAgent series with AppName=<v>: mem_used_percent, disk_used_percent,
#     and (unless heap_used disabled) jvm.memory.heap.used; heap queries are
#     scoped by ProcessGroupName when the entry sets process_group, exactly
#     like the fleet_heap_used alarm
#   - latest jvm.memory.heap.max ~= heap_max_bytes (+/-10%) — catches a
#     tfvars/-Xmx mismatch before it skews the heap alarm's byte threshold
# All fleet alarms except capacity treat missing data as notBreaching: a
# mis-dimensioned fleet would sit green forever. Exits 1 on any failure.
#
# Each query runs at the same period as the alarm it mirrors (capacity 60s, the
# per-instance queries 300s), so the printed "latest" value is comparable with
# desired_capacity / the alarm thresholds.
#
# A failed AWS CLI call is reported as an ERROR with the CLI's own message (the
# role needs cloudwatch:GetMetricData) — never silently as "no data".
#
# Assumes the tag key is AppName (the module's app_tag_key default).
#
# Usage: check_asg_fleet_metrics.sh --tfvars <path>

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

# Emits one line per fleet entry:
#   name<TAB>app_name<TAB>heap_max_bytes<TAB>check_heap<TAB>check_cpu<TAB>process_group
# heap_max_bytes and process_group print "-" when unset; check_heap is 1 unless
# heap_used is in disabled_alarms, check_cpu is 1 unless cpu is. Same
# brace-depth parser as check_jmx_metrics.sh.
#
# heap_max_bytes is an HCL expression, commonly written as a product
# (12 * 1024 * 1024 * 1024). It is evaluated as a literal integer expression via
# a restricted ast walk (int literals and + - * only, never eval); anything else
# is emitted as "?<raw>" so the caller can skip the sanity check with a warning
# instead of comparing a truncated number.
extract_fleet_entries() {
python3 - "$TFVARS" <<'EOF'
import ast, re, sys
content = open(sys.argv[1]).read()


def literal_int(expr):
    """Evaluate an integer literal expression (+ - * only). None if not one."""
    try:
        tree = ast.parse(expr.strip(), mode="eval")
    except (SyntaxError, ValueError):
        return None

    def walk(node):
        if isinstance(node, ast.Expression):
            return walk(node.body)
        if isinstance(node, ast.Constant) and isinstance(node.value, int) and not isinstance(node.value, bool):
            return node.value
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
            operand = walk(node.operand)
            if operand is None:
                return None
            return operand if isinstance(node.op, ast.UAdd) else -operand
        if isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Add, ast.Sub, ast.Mult)):
            left, right = walk(node.left), walk(node.right)
            if left is None or right is None:
                return None
            if isinstance(node.op, ast.Add):
                return left + right
            if isinstance(node.op, ast.Sub):
                return left - right
            return left * right
        return None

    return walk(tree)


start = re.search(r'asg_resources\s*=\s*\[', content)
if not start:
    sys.exit(0)

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
    nm = re.search(r'\bname\s*=\s*"([^"]+)"', e)
    ap = re.search(r'\bapp_name\s*=\s*"([^"]+)"', e)
    if not nm or not ap:
        continue  # legacy entry or malformed
    # Capture the whole right-hand side (HCL expression), not just its first int.
    hm = re.search(r'\bheap_max_bytes\s*=\s*([^,\n#}]+)', e)
    pg = re.search(r'\bprocess_group\s*=\s*"([^"]+)"', e)
    da = re.search(r'disabled_alarms\s*=\s*\[([^\]]*)\]', e)
    disabled = re.findall(r'"([^"]+)"', da.group(1)) if da else []
    check_heap = 0 if "heap_used" in disabled else 1
    check_cpu = 0 if "cpu" in disabled else 1

    heap = "-"
    if hm:
        raw = " ".join(hm.group(1).split())
        value = literal_int(raw)
        heap = str(value) if value is not None else f"?{raw}"

    print(f"{nm.group(1)}\t{ap.group(1)}\t{heap}\t{check_heap}\t{check_cpu}\t{pg.group(1) if pg else '-'}")
EOF
}

ENTRIES=$(extract_fleet_entries)

if [[ -z "$ENTRIES" ]]; then
  echo "No fleet-mode asg_resources (app_name) found in $TFVARS — skipping."
  exit 0
fi

[[ -n "$REGION" ]] || { echo "Error: aws_region not found in $TFVARS." >&2; exit 1; }

FAILED=0
START=$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ')
END=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Stderr of the last get-metric-data call. A plain file (not a variable) because
# insights_latest runs inside a command substitution, i.e. a subshell.
CLI_ERR_FILE=$(mktemp)
trap 'rm -f "$CLI_ERR_FILE"' EXIT

# Runs one Metrics Insights SELECT via get-metric-data at the given period and
# prints the latest value, or nothing when the query returned no datapoints.
# Returns the AWS CLI's exit status so callers can tell a failed call (e.g.
# AccessDenied) apart from an empty result; the CLI's stderr lands in
# $CLI_ERR_FILE.
insights_latest() {
  local EXPRESSION="$1" PERIOD="$2"
  local OUT RC
  : > "$CLI_ERR_FILE"
  set +e
  OUT=$(aws cloudwatch get-metric-data \
    --region "$REGION" \
    --start-time "$START" \
    --end-time "$END" \
    --metric-data-queries "[{\"Id\":\"q1\",\"Expression\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$EXPRESSION"),\"Period\":$PERIOD}]" \
    --query "MetricDataResults[0].Values[0]" \
    --output text 2>"$CLI_ERR_FILE")
  RC=$?
  set -e
  [[ $RC -eq 0 ]] || return "$RC"
  printf '%s\n' "$OUT" | grep -v '^None$' || true
}

# Prints the failed call's real error plus an IAM-shaped hint. AccessDenied is
# the likeliest first-run failure: the fleet checks need cloudwatch:GetMetricData
# on the preflight role, which lives outside this repo.
report_cli_failure() {
  local NAME="$1" LABEL="$2" RC="$3"
  echo "ERROR: [$NAME] $LABEL query FAILED (aws cloudwatch get-metric-data exited $RC) — this is not a 'metric missing' result:" >&2
  while IFS= read -r LINE; do
    echo "    $LINE" >&2
  done < "$CLI_ERR_FILE"
  echo "  Hint: the preflight role (PREFLIGHT_READ_ROLE_ARN) needs cloudwatch:GetMetricData. Fix the IAM policy before reading anything into the metric checks below." >&2
}

# check_query <name> <label> <expression> <hint> [period]
check_query() {
  local NAME="$1" LABEL="$2" EXPRESSION="$3" HINT="$4" PERIOD="${5:-300}"
  local VALUE RC=0
  VALUE=$(insights_latest "$EXPRESSION" "$PERIOD") || RC=$?
  if [[ $RC -ne 0 ]]; then
    report_cli_failure "$NAME" "$LABEL" "$RC"
    FAILED=1
  elif [[ -z "$VALUE" ]]; then
    echo "WARNING: [$NAME] $LABEL query returned no data. $HINT" >&2
    FAILED=1
  else
    echo "OK: [$NAME] $LABEL (latest: $VALUE)"
  fi
}

while IFS=$'\t' read -r NAME APP HEAP_MAX CHECK_HEAP CHECK_CPU PG; do
  echo "--- Fleet entry '$NAME' (AppName=$APP)"

  COUNT=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:AppName,Values=$APP" "Name=instance-state-name,Values=running" \
    --query "length(Reservations[].Instances[])" \
    --output text 2>/dev/null || echo "0")
  if [[ "$COUNT" == "0" || -z "$COUNT" ]]; then
    echo "WARNING: [$NAME] no running instances tagged AppName=$APP in $REGION. Check the launch template tag propagation." >&2
    FAILED=1
  else
    echo "OK: [$NAME] $COUNT running instance(s) tagged AppName=$APP."
  fi

  # Period 60 matches the capacity alarm's metric_query period. At 300 the SUM
  # would add five per-minute datapoints and report ~5x desired_capacity.
  check_query "$NAME" "GroupInServiceCapacity (tag telemetry)" \
    "SELECT SUM(GroupInServiceCapacity) FROM SCHEMA(\"AWS/AutoScaling\", AutoScalingGroupName) WHERE tag.AppName = '$APP'" \
    "Enable CloudWatch 'resource tags on telemetry' and tag the ASG itself with AppName=$APP." \
    60

  if [[ "$CHECK_CPU" == "1" ]]; then
    check_query "$NAME" "CPUUtilization (EC2 tag telemetry)" \
      "SELECT AVG(CPUUtilization) FROM SCHEMA(\"AWS/EC2\", InstanceId) WHERE tag.AppName = '$APP' GROUP BY InstanceId" \
      "Enable CloudWatch 'resource tags on telemetry' for EC2 instances; if unavailable, the spec's fallback is the agent-side cpu_usage_idle metric."
  fi

  check_query "$NAME" "mem_used_percent" \
    "SELECT AVG(mem_used_percent) FROM \"CWAgent\" WHERE AppName = '$APP' GROUP BY InstanceId" \
    "Deploy the cwagent/ec2-java/ config (AppName dimension on the mem plugin)."

  check_query "$NAME" "disk_used_percent" \
    "SELECT AVG(disk_used_percent) FROM \"CWAgent\" WHERE AppName = '$APP' AND path = '/' GROUP BY InstanceId" \
    "Deploy the cwagent/ec2-java/ config (AppName dimension on the disk plugin, resources ['/'])."

  if [[ "$CHECK_HEAP" == "1" ]]; then
    # Same ProcessGroupName scoping as the fleet_heap_used alarm's expression.
    PG_FILTER=""
    if [[ "$PG" != "-" ]]; then
      PG_FILTER=" AND ProcessGroupName = '$PG'"
    fi

    check_query "$NAME" "jvm.memory.heap.used" \
      "SELECT AVG(\"jvm.memory.heap.used\") FROM \"CWAgent\" WHERE AppName = '$APP'$PG_FILTER GROUP BY InstanceId" \
      "Deploy the cwagent/ec2-java/ config and expose the JMX endpoint on the JVM."

    if [[ "$HEAP_MAX" == \?* ]]; then
      echo "WARNING: [$NAME] could not parse heap_max_bytes as a literal integer expression (got: ${HEAP_MAX#\?}); skipping the heap_max sanity check. Verify the JVM -Xmx by hand." >&2
    elif [[ "$HEAP_MAX" != "-" ]]; then
      RC=0
      ACTUAL_MAX=$(insights_latest "SELECT MAX(\"jvm.memory.heap.max\") FROM \"CWAgent\" WHERE AppName = '$APP'$PG_FILTER" 300) || RC=$?
      if [[ $RC -ne 0 ]]; then
        report_cli_failure "$NAME" "jvm.memory.heap.max" "$RC"
        FAILED=1
      elif [[ -z "$ACTUAL_MAX" ]]; then
        echo "WARNING: [$NAME] jvm.memory.heap.max query returned no data; cannot sanity-check heap_max_bytes=$HEAP_MAX." >&2
        FAILED=1
      else
        WITHIN=$(python3 -c "import sys; a=float(sys.argv[1]); e=float(sys.argv[2]); print(1 if abs(a-e)/e <= 0.10 else 0)" "$ACTUAL_MAX" "$HEAP_MAX")
        if [[ "$WITHIN" == "1" ]]; then
          echo "OK: [$NAME] heap_max_bytes=$HEAP_MAX matches observed jvm.memory.heap.max=$ACTUAL_MAX (±10%)."
        else
          echo "WARNING: [$NAME] heap_max_bytes=$HEAP_MAX but observed jvm.memory.heap.max=$ACTUAL_MAX (>10% off). Fix tfvars or -Xmx; the heap alarm threshold derives from this." >&2
          FAILED=1
        fi
      fi
    fi
  fi
done <<< "$ENTRIES"

exit "$FAILED"
