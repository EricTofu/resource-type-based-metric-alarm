#!/usr/bin/env bash
# Checks jmx_resources prerequisites by running the SAME Metrics Insights
# queries the JMX alarms use (see modules/cloudwatch/metrics-alarm/jmx/main.tf):
#   - heap_used alarm -> SELECT AVG(jvm_memory_heap_used) FROM "CWAgent" WHERE
#     AppName = '<app>' GROUP BY InstanceId
#   - gc_time  alarm -> SELECT SUM(jvm_gc_collections_elapsed) FROM "CWAgent"
#     WHERE AppName = '<app>' GROUP BY InstanceId
#   - latest jvm_memory_heap_max ~= heap_max_bytes (+/-10%) — catches a
#     tfvars/-Xmx mismatch before it skews the heap alarm's byte threshold
# Both alarms scope by ProcessGroupName when the entry sets process_group,
# exactly like the module, and both queries run at period=60 to match.
#
# Both JMX alarms treat missing data as notBreaching: a host group with no
# AppName dimension (agent not deployed, or deployed with the wrong AppName)
# would sit green forever rather than failing loudly. This script assumes JVM
# metric names are snake_case, per the agent config in cwagent/ec2-java/.
#
# A failed AWS CLI call is reported as an ERROR with the CLI's own message (the
# preflight role needs cloudwatch:GetMetricData) — never silently as "no data".
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

# Emits one line per jmx_resources entry, each prefixed with a type column:
#   ENTRY<TAB>name<TAB>app_name<TAB>heap_max_bytes<TAB>check_heap<TAB>check_gc<TAB>process_group
# heap_max_bytes and process_group print "-" when unset; check_heap is 1
# unless heap_used is in disabled_alarms, check_gc is 1 unless gc_time is.
# Entries missing app_name or name are malformed (app_name is now the required
# identity; name is required for alarm-naming/output purposes) and are instead
# emitted as:
#   MALFORMED<TAB>message
# The type column is a hardcoded Python string literal, never built from
# tfvars content, so it cannot collide with a user-supplied field — e.g. a
# resource whose `name` is literally "MALFORMED" still emits ENTRY\tMALFORMED\t...
# The caller (running outside this subshell) splits on the leading column,
# counts MALFORMED lines, echoes them as warnings, and fails the preflight
# instead of silently reporting "no entries found".
#
# heap_max_bytes is an HCL expression, commonly written as a product
# (12 * 1024 * 1024 * 1024). It is evaluated as a literal integer expression via
# a restricted ast walk (int literals and + - * only, never eval); anything else
# is emitted as "?" so the caller can skip the sanity check with a warning
# instead of comparing a truncated number. "-" (key absent) and "?" (unparseable)
# differ deliberately: only the absent case is silent.
extract_jmx_entries() {
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


start = re.search(r'jmx_resources\s*=\s*\[', content)
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
    # \b anchors on the whole key: unanchored 'name' also matches app_name.
    nm = re.search(r'\bname\s*=\s*"([^"]+)"', e)
    ap = re.search(r'\bapp_name\s*=\s*"([^"]+)"', e)
    if not nm and not ap:
        continue  # neither identifying field present; nothing to name the warning after
    if not ap:
        # Type column emitted first, hardcoded here (never interpolated from
        # tfvars content) — see the caller for why this makes the
        # ENTRY/MALFORMED discriminator collision-proof against any name a
        # user could write, including a resource literally named "MALFORMED".
        print(f"MALFORMED\tapp_name is required; skipping entry with no app_name (name={nm.group(1)})")
        continue
    if not nm:
        print(f"MALFORMED\tname is required; skipping entry with app_name={ap.group(1)} but no name")
        continue
    hm = re.search(r'\bheap_max_bytes\s*=\s*([^,\n#}]+)', e)
    pg = re.search(r'\bprocess_group\s*=\s*"([^"]+)"', e)
    da = re.search(r'disabled_alarms\s*=\s*\[([^\]]*)\]', e)
    disabled = re.findall(r'"([^"]+)"', da.group(1)) if da else []
    check_heap = 0 if "heap_used" in disabled else 1
    check_gc = 0 if "gc_time" in disabled else 1

    heap = "-"
    if hm:
        raw = " ".join(hm.group(1).split())
        value = literal_int(raw)
        heap = str(value) if value is not None else "?"

    # Leading "ENTRY" type column — see the caller for why this, not a string
    # prefix on the whole line, is what makes the discriminator collision-proof.
    print(f"ENTRY\t{nm.group(1)}\t{ap.group(1)}\t{heap}\t{check_heap}\t{check_gc}\t{pg.group(1) if pg else '-'}")
EOF
}

RAW_ENTRIES=$(extract_jmx_entries)

# Every line from extract_jmx_entries starts with a type column, "ENTRY" or
# "MALFORMED", written as a Python string literal in the code above — never
# built from anything read out of tfvars. That makes it collision-proof
# against user data: a resource whose `name` is literally "MALFORMED" still
# comes out as ENTRY\tMALFORMED\t<app_name>\t..., so TYPE (the first
# tab-separated field, split off below) is "ENTRY", not "MALFORMED", no matter
# what the name/app_name/etc. fields contain. Do NOT go back to matching a
# string prefix on the whole line — that was the round-1 bug this replaced.
MALFORMED_COUNT=0
ENTRIES=""
if [[ -n "$RAW_ENTRIES" ]]; then
  while IFS=$'\t' read -r TYPE REST; do
    case "$TYPE" in
      MALFORMED)
        echo "WARNING: $REST" >&2
        MALFORMED_COUNT=$((MALFORMED_COUNT + 1))
        ;;
      ENTRY)
        ENTRIES+="$REST"$'\n'
        ;;
    esac
  done <<< "$RAW_ENTRIES"
fi
ENTRIES="${ENTRIES%$'\n'}"

if [[ -z "$ENTRIES" && "$MALFORMED_COUNT" -eq 0 ]]; then
  echo "No jmx_resources found in $TFVARS — skipping."
  exit 0
fi

[[ -n "$REGION" ]] || { echo "Error: aws_region not found in $TFVARS." >&2; exit 1; }

FAILED=0
if [[ "$MALFORMED_COUNT" -gt 0 ]]; then
  echo "ERROR: $MALFORMED_COUNT malformed jmx_resources entry/entries in $TFVARS (see WARNING lines above) — app_name and name are both required." >&2
  FAILED=1
fi
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
# the likeliest first-run failure: the JMX checks need cloudwatch:GetMetricData
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
    echo "WARNING: [$NAME] $LABEL query returned no data. $HINT Query: $EXPRESSION" >&2
    FAILED=1
  else
    echo "OK: [$NAME] $LABEL (latest: $VALUE)"
  fi
}

CWAGENT_HINT="Deploy the cwagent/ec2-java/ config (AppName dimension on the jmx plugin) and expose the JMX endpoint on the JVM."

# ENTRIES can be empty here (all entries were malformed) while MALFORMED_COUNT
# still failed the run above; guard the loop so an empty ENTRIES doesn't feed
# `read` one blank line and iterate once with everything unset.
if [[ -n "$ENTRIES" ]]; then
while IFS=$'\t' read -r NAME APP HEAP_MAX CHECK_HEAP CHECK_GC PG; do
  echo "--- JMX entry '$NAME' (AppName=$APP)"

  PG_FILTER=""
  if [[ "$PG" != "-" ]]; then
    PG_FILTER=" AND ProcessGroupName = '$PG'"
  fi

  if [[ "$CHECK_HEAP" == "1" ]]; then
    check_query "$NAME" "jvm_memory_heap_used" \
      "SELECT AVG(jvm_memory_heap_used) FROM \"CWAgent\" WHERE AppName = '$APP'$PG_FILTER GROUP BY InstanceId" \
      "$CWAGENT_HINT" 60
  fi

  if [[ "$CHECK_GC" == "1" ]]; then
    check_query "$NAME" "jvm_gc_collections_elapsed" \
      "SELECT SUM(jvm_gc_collections_elapsed) FROM \"CWAgent\" WHERE AppName = '$APP'$PG_FILTER GROUP BY InstanceId" \
      "$CWAGENT_HINT" 60
  fi

  if [[ "$CHECK_HEAP" == "1" && "$HEAP_MAX" != "-" && "$HEAP_MAX" != "?" ]]; then
    HEAP_MAX_QUERY="SELECT MAX(jvm_memory_heap_max) FROM \"CWAgent\" WHERE AppName = '$APP'$PG_FILTER"
    # Resolved heap_max_bytes (post ast-eval, e.g. 12 * 1024 * 1024 * 1024 ->
    # 12884901888) plus the query, echoed unconditionally so a hard CLI
    # failure still leaves both in the transcript for diagnosis.
    echo "    heap_max_bytes resolved to $HEAP_MAX; Query [jvm_memory_heap_max]: $HEAP_MAX_QUERY"
    RC=0
    ACTUAL_MAX=$(insights_latest "$HEAP_MAX_QUERY" 60) || RC=$?
    if [[ $RC -ne 0 ]]; then
      report_cli_failure "$NAME" "jvm_memory_heap_max" "$RC"
      FAILED=1
    elif [[ -z "$ACTUAL_MAX" ]]; then
      echo "WARNING: [$NAME] jvm_memory_heap_max query returned no data; cannot sanity-check heap_max_bytes=$HEAP_MAX." >&2
      FAILED=1
    else
      # e<=0 (zero or negative heap_max_bytes) is guarded inside python: it
      # would otherwise raise ZeroDivisionError (e=0, killing the whole script
      # under set -e, never reaching later entries) or silently report a
      # false OK (e<0 makes abs(a-e)/e negative, which is <= 0.10). The RC is
      # also captured so any other python failure degrades to a warning
      # instead of aborting the script, matching the RC-capture fix applied
      # to the insights_latest call just above.
      WITHIN_RC=0
      WITHIN=$(python3 -c "
import sys
a = float(sys.argv[1])
e = float(sys.argv[2])
if e <= 0:
    print('invalid')
else:
    print(1 if abs(a - e) / e <= 0.10 else 0)
" "$ACTUAL_MAX" "$HEAP_MAX") || WITHIN_RC=$?
      if [[ $WITHIN_RC -ne 0 ]]; then
        echo "WARNING: [$NAME] could not evaluate the heap_max_bytes comparison (python exited $WITHIN_RC); heap_max_bytes=$HEAP_MAX, observed jvm_memory_heap_max=$ACTUAL_MAX." >&2
        FAILED=1
      elif [[ "$WITHIN" == "invalid" ]]; then
        echo "WARNING: [$NAME] heap_max_bytes=$HEAP_MAX is not a positive number; cannot sanity-check against observed jvm_memory_heap_max=$ACTUAL_MAX. Fix tfvars — the heap alarm threshold derives from this." >&2
        FAILED=1
      elif [[ "$WITHIN" == "1" ]]; then
        echo "OK: [$NAME] heap_max_bytes=$HEAP_MAX matches observed jvm_memory_heap_max=$ACTUAL_MAX (±10%)."
      else
        echo "WARNING: [$NAME] heap_max_bytes=$HEAP_MAX but observed jvm_memory_heap_max=$ACTUAL_MAX (>10% off). Fix tfvars or -Xmx; the heap alarm threshold derives from this." >&2
        FAILED=1
      fi
    fi
  elif [[ "$CHECK_HEAP" == "1" && "$HEAP_MAX" == "?" ]]; then
    echo "WARNING: [$NAME] could not parse heap_max_bytes as a literal expression; skipping the heap_max sanity check." >&2
  fi
done <<< "$ENTRIES"
fi

exit "$FAILED"
