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
# On a no-data result the script also runs `list-metrics --recently-active PT3H`
# (needs cloudwatch:ListMetrics) as a first-line diagnostic: that flag's window is
# the same ~3h one Metrics Insights can see, so it separates "the metric does not
# exist" (agent config not deployed / name not renamed) from "it exists but the
# AppName/ProcessGroupName filter matched nothing".
#
# --cwagent-dimension-key <key> (default AppName): the CloudWatch Agent
# *dimension* name carrying the fleet identity, mirroring the jmx module's
# variable of the same name. It is fixed by the agent config, and it is NOT the
# asg module's resource tag key — the two default to the same string and are set
# in different systems.
#
# Usage: check_jmx_metrics.sh --tfvars <path> [--cwagent-dimension-key <key>]
# Example: check_jmx_metrics.sh --tfvars stacks/projects/billing/dev/terraform.tfvars

set -euo pipefail

TFVARS=""
# CWAgent *dimension* name (agent config), never a resource tag key.
CWAGENT_DIMENSION_KEY="AppName"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tfvars) TFVARS="$2"; shift 2 ;;
    --cwagent-dimension-key) CWAGENT_DIMENSION_KEY="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$TFVARS" ]]; then
  echo "Usage: $0 --tfvars <path> [--cwagent-dimension-key <key>]" >&2
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

# Emits one line per jmx_resources entry, each prefixed with a type column:
#   ENTRY<TAB>name<TAB>dim_value<TAB>heap_max_bytes<TAB>check_heap<TAB>check_gc<TAB>process_group
# heap_max_bytes and process_group print "-" when unset; check_heap is 1
# unless heap_used is in disabled_alarms, check_gc is 1 unless gc_time is.
# Entries missing cwagent_dimension_value or name are malformed (it is the required
# identity; name is required for alarm-naming/output purposes) and are instead
# emitted as:
#   MALFORMED<TAB>message
# Plus exactly one line describing how the jmx_resources list itself parsed:
#   STATUS<TAB>absent|empty|unterminated|unbalanced-braces|unparsed|parsed:<n>
# The caller turns everything except `absent` and `empty` into a hard failure
# when no ENTRY line came out, so a parser that silently extracts nothing can no
# longer be reported as a pass (see the skip path below).
#
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
# both warn: a heap_max_bytes that cannot be reconciled is never silent, because
# the heap alarm's byte threshold is derived from it.
extract_jmx_entries() {
python3 - "$TFVARS" <<'EOF'
import ast, re, sys
content = open(sys.argv[1]).read()

# Strip line comments BEFORE any bracket/brace counting. Both scans below are
# plain character counters over raw text, so without this:
#   (a) an unbalanced `{` inside a comment inside the list ended the array scan
#       early and the script reported success having run zero checks, and
#   (b) a *balanced* commented-out entry was parsed as live, so the run queried a
#       decommissioned AppName and failed.
# Verified that no tfvars in this repo puts `#` or `//` inside a string literal,
# which is the only thing this would corrupt; if one ever does, this needs a real
# HCL tokenizer. HCL `/* */` block comments are not used anywhere here and are
# NOT handled — the STATUS/"extracted nothing" failure below is the backstop.
content = re.sub(r'(?m)#.*$|//.*$', '', content)


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
    print("STATUS\tabsent")
    sys.exit(0)

i, depth, body, terminated = start.end(), 1, [], False
while i < len(content):
    c = content[i]
    if c == '[':
        depth += 1
    elif c == ']':
        depth -= 1
        if depth == 0:
            terminated = True
            break
    body.append(c)
    i += 1
if not terminated:
    print("STATUS\tunterminated")
    sys.exit(0)
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

if depth != 0:
    print("STATUS\tunbalanced-braces")
    sys.exit(0)
if not entries:
    print("STATUS\tempty" if not body.strip() else "STATUS\tunparsed")
    sys.exit(0)
print(f"STATUS\tparsed:{len(entries)}")

for e in entries:
    # \b anchors on the whole key: unanchored 'name' also matches other keys.
    nm = re.search(r'\bname\s*=\s*"([^"]+)"', e)
    ap = re.search(r'\bcwagent_dimension_value\s*=\s*"([^"]+)"', e)
    if not nm and not ap:
        # Neither identifying field present, so there is nothing to name the
        # warning after — but it is still an object inside jmx_resources, and
        # skipping it silently is how "matched but extracted nothing" used to
        # become a pass. Report it and let the caller fail the run.
        print("MALFORMED\tan entry object has neither name nor cwagent_dimension_value (both are required)")
        continue
    if not ap:
        # Type column emitted first, hardcoded here (never interpolated from
        # tfvars content) — see the caller for why this makes the
        # ENTRY/MALFORMED discriminator collision-proof against any name a
        # user could write, including a resource literally named "MALFORMED".
        print(f"MALFORMED\tcwagent_dimension_value is required; skipping entry without one (name={nm.group(1)})")
        continue
    if not nm:
        print(f"MALFORMED\tname is required; skipping entry with cwagent_dimension_value={ap.group(1)} but no name")
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
# comes out as ENTRY\tMALFORMED\t<dim_value>\t..., so TYPE (the first
# tab-separated field, split off below) is "ENTRY", not "MALFORMED", no matter
# what the name/identity/etc. fields contain. Do NOT go back to matching a
# string prefix on the whole line — that was the round-1 bug this replaced.
MALFORMED_COUNT=0
ENTRIES=""
PARSE_STATUS=""
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
      STATUS)
        PARSE_STATUS="$REST"
        ;;
    esac
  done <<< "$RAW_ENTRIES"
fi
ENTRIES="${ENTRIES%$'\n'}"

# Exiting 0 having run no checks is only legitimate when there is genuinely
# nothing to check: no jmx_resources block at all, or a literal empty list.
# Anything else — a truncated/unbalanced list, a body the entry splitter could
# not turn into objects, or objects that yielded neither an ENTRY nor a
# MALFORMED line — means the parser did not understand the config, and since
# both JMX alarms are treat_missing_data=notBreaching this script is the only
# guard between a typo'd identity value and an alarm that stays green forever. Fail
# loudly instead of passing silently.
if [[ -z "$ENTRIES" && "$MALFORMED_COUNT" -eq 0 ]]; then
  case "$PARSE_STATUS" in
    absent)
      echo "No jmx_resources block in $TFVARS — skipping."
      exit 0
      ;;
    empty)
      echo "jmx_resources is an empty list in $TFVARS — skipping."
      exit 0
      ;;
    unterminated)
      echo "ERROR: jmx_resources in $TFVARS is not terminated (no matching ']'). Refusing to report success without running any check — fix the tfvars syntax." >&2
      exit 1
      ;;
    unbalanced-braces)
      echo "ERROR: jmx_resources in $TFVARS has unbalanced '{'/'}' — the entry parser could not split it. Refusing to report success without running any check — fix the tfvars syntax." >&2
      exit 1
      ;;
    *)
      echo "ERROR: jmx_resources was found in $TFVARS but no entries could be extracted from it (parser status: ${PARSE_STATUS:-none}). Refusing to report success without running any check — fix the tfvars, or the parser in this script." >&2
      exit 1
      ;;
  esac
fi

[[ -n "$REGION" ]] || { echo "Error: aws_region not found in $TFVARS." >&2; exit 1; }

FAILED=0
if [[ "$MALFORMED_COUNT" -gt 0 ]]; then
  echo "ERROR: $MALFORMED_COUNT malformed jmx_resources entry/entries in $TFVARS (see WARNING lines above) — cwagent_dimension_value and name are both required." >&2
  FAILED=1
fi
START=$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ')
END=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Stderr of the last get-metric-data call. A plain file (not a variable) because
# insights_latest runs inside a command substitution, i.e. a subshell.
CLI_ERR_FILE=$(mktemp)
trap 'rm -f "$CLI_ERR_FILE"' EXIT

# Runs one Metrics Insights SELECT via get-metric-data at the given period and
# prints "<series-count><TAB><latest-value>". <latest-value> is empty when no
# returned series had a datapoint. Returns the AWS CLI's exit status so callers
# can tell a failed call (e.g. AccessDenied) apart from an empty result; the CLI's
# stderr lands in $CLI_ERR_FILE.
#
# Why not MetricDataResults[0]: a GROUP BY InstanceId query returns one result
# per matched series in no guaranteed order, and Metrics Insights matches any
# series with data in roughly the last 3h — wider than this script's 1h window.
# So an instance terminated 90 minutes ago (routine right after a blue/green
# deploy) comes back with an empty Values array, and if it sorted first the
# script reported "no data" while the live fleet was reporting normally. The
# filter takes the first result that actually HAS a datapoint. The series count
# is printed alongside so an operator can compare it with desired_capacity.
insights_latest() {
  local EXPRESSION="$1" PERIOD="$2"
  local OUT RC COUNT VALUE
  : > "$CLI_ERR_FILE"
  set +e
  OUT=$(aws cloudwatch get-metric-data \
    --region "$REGION" \
    --start-time "$START" \
    --end-time "$END" \
    --metric-data-queries "[{\"Id\":\"q1\",\"Expression\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$EXPRESSION"),\"Period\":$PERIOD}]" \
    --query "[length(MetricDataResults), MetricDataResults[?length(Values) > \`0\`] | [0].Values[0]]" \
    --output text 2>"$CLI_ERR_FILE")
  RC=$?
  set -e
  [[ $RC -eq 0 ]] || return "$RC"
  # `--output text` renders a flat scalar list as one tab-separated line; the
  # tr collapses any whitespace so a per-line rendering parses identically.
  read -r COUNT VALUE <<< "$(printf '%s' "$OUT" | tr '\n\t' '  ')"
  if [[ "$VALUE" == "None" ]]; then
    VALUE=""
  fi
  printf '%s\t%s\n' "${COUNT:-0}" "$VALUE"
}

# On a no-data result, separate "the metric does not exist at all" from "it
# exists but the WHERE filter matched nothing" — the most common confusion
# during the snake_case rename / AppName rollout. --recently-active PT3H is the
# same ~3h window Metrics Insights itself can see, so a metric absent from it is
# not queryable regardless of query syntax.
#
# The metric name is deliberately NOT echoed in these lines: the no-data WARNING
# right above already carries the full query, and keeping each JVM metric name to
# one occurrence per failing check preserves `grep <metric> ` on this script's
# output as a count of failures.
list_metrics_diag() {
  local NAMESPACE="$1" METRIC="$2"
  [[ -n "$NAMESPACE" && -n "$METRIC" ]] || return 0
  local COUNT RC=0
  COUNT=$(aws cloudwatch list-metrics \
    --namespace "$NAMESPACE" \
    --metric-name "$METRIC" \
    --recently-active PT3H \
    --region "$REGION" \
    --query "length(Metrics)" \
    --output text 2>/dev/null) || RC=$?
  if [[ $RC -ne 0 || -z "$COUNT" ]]; then
    echo "  Diagnostic: list-metrics --recently-active PT3H could not be run (the preflight role also needs cloudwatch:ListMetrics)." >&2
  elif [[ "$COUNT" == "0" ]]; then
    echo "  Diagnostic: list-metrics --recently-active PT3H found 0 recently-active series for this metric in $NAMESPACE — the metric itself is absent (agent config not deployed, or the JVM metrics not renamed to snake_case), not merely mis-filtered." >&2
  else
    echo "  Diagnostic: list-metrics --recently-active PT3H found $COUNT recently-active series for this metric in $NAMESPACE — the metric exists, so it is the WHERE filter (${CWAGENT_DIMENSION_KEY} / ProcessGroupName) that matched nothing." >&2
  fi
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

# check_query <name> <label> <expression> <hint> [period] [namespace] [metric]
# namespace/metric are only used for the list-metrics no-data diagnostic.
check_query() {
  local NAME="$1" LABEL="$2" EXPRESSION="$3" HINT="$4" PERIOD="${5:-300}" NAMESPACE="${6:-}" METRIC="${7:-}"
  local RESULT COUNT VALUE RC=0
  RESULT=$(insights_latest "$EXPRESSION" "$PERIOD") || RC=$?
  if [[ $RC -ne 0 ]]; then
    report_cli_failure "$NAME" "$LABEL" "$RC"
    FAILED=1
    return 0
  fi
  IFS=$'\t' read -r COUNT VALUE <<< "$RESULT"
  if [[ -z "$VALUE" ]]; then
    echo "WARNING: [$NAME] $LABEL query returned no data ($COUNT series matched). $HINT Query: $EXPRESSION" >&2
    list_metrics_diag "$NAMESPACE" "$METRIC"
    FAILED=1
  else
    echo "OK: [$NAME] $LABEL (latest: $VALUE; $COUNT series returned — compare with the expected instance count)"
  fi
}

CWAGENT_HINT="Deploy the cwagent/ec2-java/ config (AppName dimension on the jmx plugin) and expose the JMX endpoint on the JVM."

# ENTRIES can be empty here (all entries were malformed) while MALFORMED_COUNT
# still failed the run above; guard the loop so an empty ENTRIES doesn't feed
# `read` one blank line and iterate once with everything unset.
if [[ -n "$ENTRIES" ]]; then
while IFS=$'\t' read -r NAME APP HEAP_MAX CHECK_HEAP CHECK_GC PG; do
  echo "--- JMX entry '$NAME' (${CWAGENT_DIMENSION_KEY}=$APP)"

  PG_FILTER=""
  if [[ "$PG" != "-" ]]; then
    PG_FILTER=" AND ProcessGroupName = '$PG'"
  fi

  if [[ "$CHECK_HEAP" == "1" ]]; then
    check_query "$NAME" "jvm_memory_heap_used" \
      "SELECT AVG(jvm_memory_heap_used) FROM \"CWAgent\" WHERE ${CWAGENT_DIMENSION_KEY} = '$APP'$PG_FILTER GROUP BY InstanceId ORDER BY AVG() DESC" \
      "$CWAGENT_HINT" 60 "CWAgent" "jvm_memory_heap_used"
  fi

  if [[ "$CHECK_GC" == "1" ]]; then
    check_query "$NAME" "jvm_gc_collections_elapsed" \
      "SELECT SUM(jvm_gc_collections_elapsed) FROM \"CWAgent\" WHERE ${CWAGENT_DIMENSION_KEY} = '$APP'$PG_FILTER GROUP BY InstanceId ORDER BY SUM() DESC" \
      "$CWAGENT_HINT" 60 "CWAgent" "jvm_gc_collections_elapsed"
  fi

  if [[ "$CHECK_HEAP" == "1" && "$HEAP_MAX" != "-" && "$HEAP_MAX" != "?" ]]; then
    HEAP_MAX_QUERY="SELECT MAX(jvm_memory_heap_max) FROM \"CWAgent\" WHERE ${CWAGENT_DIMENSION_KEY} = '$APP'$PG_FILTER"
    # Resolved heap_max_bytes (post ast-eval, e.g. 12 * 1024 * 1024 * 1024 ->
    # 12884901888) plus the query, echoed unconditionally so a hard CLI
    # failure still leaves both in the transcript for diagnosis.
    echo "    heap_max_bytes resolved to $HEAP_MAX; Query [jvm_memory_heap_max]: $HEAP_MAX_QUERY"
    RC=0
    MAX_RESULT=$(insights_latest "$HEAP_MAX_QUERY" 60) || RC=$?
    IFS=$'\t' read -r MAX_COUNT ACTUAL_MAX <<< "${MAX_RESULT:-}"
    if [[ $RC -ne 0 ]]; then
      report_cli_failure "$NAME" "jvm_memory_heap_max" "$RC"
      FAILED=1
    elif [[ -z "$ACTUAL_MAX" ]]; then
      echo "WARNING: [$NAME] jvm_memory_heap_max query returned no data ($MAX_COUNT series matched); cannot sanity-check heap_max_bytes=$HEAP_MAX." >&2
      list_metrics_diag "CWAgent" "jvm_memory_heap_max"
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
  elif [[ "$CHECK_HEAP" == "1" ]]; then
    # HEAP_MAX == "-": the key is absent. The module rejects that config
    # (heap_max_bytes is required unless heap_used is disabled), but say so here
    # too rather than skipping the ±10% reconciliation in silence.
    echo "WARNING: [$NAME] heap_used is enabled but heap_max_bytes is not set; skipping the heap_max sanity check (the module will reject this config — heap_max_bytes is the heap alarm's byte threshold)." >&2
  fi
done <<< "$ENTRIES"
fi

exit "$FAILED"
