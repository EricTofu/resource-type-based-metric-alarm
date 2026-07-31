#!/usr/bin/env bash
# Checks fleet-mode asg_resources (entries with app_name) prerequisites by
# running the SAME Metrics Insights queries the fleet alarms use:
#   - running EC2 instances tagged <app-tag-key>=<v> exist
#   - tag-scoped GroupInServiceCapacity query returns data (proves the
#     CloudWatch "resource tags on telemetry" setting + ASG tag)
#   - (unless cpu disabled) tag-scoped CPUUtilization query returns data
#     (proves tag telemetry for AWS/EC2 — a separate path from AWS/AutoScaling)
#   - (unless memory/disk disabled) CWAgent series with AppName=<v>:
#     mem_used_percent, disk_used_percent
# Every per-metric check honours overrides.disabled_alarms, so an entry that opts
# out of an alarm is not asked for its series (same precedent as
# scripts/check_ec2_mem_metric.sh).
# All fleet alarms except capacity treat missing data as notBreaching: a
# mis-dimensioned fleet would sit green forever. Exits 1 on any failure.
#
# JVM heap/GC prerequisites (jvm_memory_heap_used/max, jvm_gc_collections_elapsed)
# moved to the jmx module and are checked by scripts/check_jmx_metrics.sh, not
# here — this script only covers the ASG/EC2-fleet alarms.
#
# Each query runs at the same period as the alarm it mirrors (capacity 60s, the
# per-instance queries 300s), so the printed "latest" value is comparable with
# desired_capacity / the alarm thresholds.
#
# A failed AWS CLI call is reported as an ERROR with the CLI's own message (the
# role needs cloudwatch:GetMetricData) — never silently as "no data".
# On a no-data result the script also runs `list-metrics --recently-active PT3H`
# (needs cloudwatch:ListMetrics) as a first-line diagnostic: that flag's window is
# the same ~3h one Metrics Insights can see, so it separates "the metric does not
# exist" from "it exists but the tag/AppName filter matched nothing".
#
# --app-tag-key <key> (default AppName): the EC2/ASG *resource tag* key used by
# the two native-metric queries (GroupInServiceCapacity on AWS/AutoScaling,
# CPUUtilization on AWS/EC2) and the describe-instances tag filter — this key
# is configurable, mirroring the module's app_tag_key variable. The CWAgent
# queries (mem_used_percent, disk_used_percent) stay hardcoded to the literal
# AppName *dimension*, which is fixed by the agent config and is NOT the tag
# key — do not wire --app-tag-key into those.
#
# Usage: check_asg_fleet_metrics.sh --tfvars <path> [--app-tag-key <key>]

set -euo pipefail

TFVARS=""
# Resource *tag* key (not a metric dimension — see the header comment above
# for why this is only wired into the native-metric queries and the
# describe-instances filter, never into the CWAgent queries).
APP_TAG_KEY="AppName"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tfvars) TFVARS="$2"; shift 2 ;;
    --app-tag-key) APP_TAG_KEY="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$TFVARS" ]]; then
  echo "Usage: $0 --tfvars <path> [--app-tag-key <key>]" >&2
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

# Emits one line per fleet entry, prefixed with a hardcoded type column:
#   ENTRY<TAB>name<TAB>app_name<TAB>check_cpu<TAB>check_memory<TAB>check_disk
# check_* is 0 when that metric's alarm id is in overrides.disabled_alarms, so an
# entry opting out of an alarm is not asked for its series.
# Plus exactly one line describing how the asg_resources list itself parsed:
#   STATUS<TAB>absent|empty|unterminated|unbalanced-braces|unparsed|parsed:<n>
# The caller needs that to tell "no fleet entries among N legacy entries" (a
# legitimate skip) from "the parser understood nothing" (a failure). Same
# brace-depth parser as check_jmx_metrics.sh.
#
# The type column is a hardcoded Python string literal, never interpolated from
# tfvars content, so no user-supplied name can collide with it.
extract_fleet_entries() {
python3 - "$TFVARS" <<'EOF'
import re, sys
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

start = re.search(r'asg_resources\s*=\s*\[', content)
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
    nm = re.search(r'\bname\s*=\s*"([^"]+)"', e)
    ap = re.search(r'\bapp_name\s*=\s*"([^"]+)"', e)
    if not nm or not ap:
        continue  # legacy entry (no app_name) — check_asg_metrics.sh covers it
    da = re.search(r'disabled_alarms\s*=\s*\[([^\]]*)\]', e)
    disabled = re.findall(r'"([^"]+)"', da.group(1)) if da else []
    check_cpu = 0 if "cpu" in disabled else 1
    check_memory = 0 if "memory" in disabled else 1
    check_disk = 0 if "disk" in disabled else 1

    print(f"ENTRY\t{nm.group(1)}\t{ap.group(1)}\t{check_cpu}\t{check_memory}\t{check_disk}")
EOF
}

RAW_ENTRIES=$(extract_fleet_entries)

ENTRIES=""
PARSE_STATUS=""
if [[ -n "$RAW_ENTRIES" ]]; then
  while IFS=$'\t' read -r TYPE REST; do
    case "$TYPE" in
      STATUS) PARSE_STATUS="$REST" ;;
      ENTRY) ENTRIES+="$REST"$'\n' ;;
    esac
  done <<< "$RAW_ENTRIES"
fi
ENTRIES="${ENTRIES%$'\n'}"

# Exiting 0 having run no checks is only legitimate when there is genuinely
# nothing to check: no asg_resources block, a literal empty list, or a list whose
# entries are all legacy (they are covered by check_asg_metrics.sh). Anything
# else — a truncated/unbalanced list, or a body the entry splitter could not turn
# into objects — means the parser did not understand the config, and every fleet
# alarm except capacity is treat_missing_data=notBreaching, so a silent pass here
# is how a typo'd app_name reaches production green. Fail loudly instead.
if [[ -z "$ENTRIES" ]]; then
  case "$PARSE_STATUS" in
    absent)
      echo "No asg_resources block in $TFVARS — skipping."
      exit 0
      ;;
    empty)
      echo "asg_resources is an empty list in $TFVARS — skipping."
      exit 0
      ;;
    parsed:*)
      echo "No fleet-mode asg_resources (app_name) among ${PARSE_STATUS#parsed:} asg_resources entry/entries in $TFVARS — skipping (legacy entries are checked by check_asg_metrics.sh)."
      exit 0
      ;;
    unterminated)
      echo "ERROR: asg_resources in $TFVARS is not terminated (no matching ']'). Refusing to report success without running any check — fix the tfvars syntax." >&2
      exit 1
      ;;
    unbalanced-braces)
      echo "ERROR: asg_resources in $TFVARS has unbalanced '{'/'}' — the entry parser could not split it. Refusing to report success without running any check — fix the tfvars syntax." >&2
      exit 1
      ;;
    *)
      echo "ERROR: asg_resources was found in $TFVARS but no entries could be extracted from it (parser status: ${PARSE_STATUS:-none}). Refusing to report success without running any check — fix the tfvars, or the parser in this script." >&2
      exit 1
      ;;
  esac
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
# exists but the WHERE filter matched nothing" — the most common confusion during
# the AppName/rename rollout, and for the two native-metric queries the usual
# answer ("the metric exists, the tag filter matched nothing") points straight at
# the CloudWatch "resource tags on telemetry" setting. --recently-active PT3H is
# the same ~3h window Metrics Insights itself can see, so a metric absent from it
# is not queryable regardless of query syntax.
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
    echo "  Diagnostic: list-metrics --recently-active PT3H found 0 recently-active series for $METRIC in $NAMESPACE — the metric itself is absent (no ASG group metrics collection / no CloudWatch Agent), not merely mis-filtered." >&2
  else
    echo "  Diagnostic: list-metrics --recently-active PT3H found $COUNT recently-active series for $METRIC in $NAMESPACE — the metric exists, so it is the WHERE filter (tag.${APP_TAG_KEY} / AppName / path) that matched nothing." >&2
  fi
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

# check_query <name> <label> <expression> <hint> [period] [namespace] [metric]
# namespace/metric are only used for the list-metrics no-data diagnostic.
check_query() {
  local NAME="$1" LABEL="$2" EXPRESSION="$3" HINT="$4" PERIOD="${5:-300}" NAMESPACE="${6:-}" METRIC="${7:-}"
  local RESULT COUNT VALUE RC=0
  # Echoed unconditionally (not just on the no-data WARNING) so a hard CLI
  # failure (e.g. AccessDenied) still leaves the exact query — including which
  # tag key it used — in the transcript for diagnosis.
  echo "    Query [$LABEL]: $EXPRESSION"
  RESULT=$(insights_latest "$EXPRESSION" "$PERIOD") || RC=$?
  if [[ $RC -ne 0 ]]; then
    report_cli_failure "$NAME" "$LABEL" "$RC"
    FAILED=1
    return 0
  fi
  IFS=$'\t' read -r COUNT VALUE <<< "$RESULT"
  if [[ -z "$VALUE" ]]; then
    echo "WARNING: [$NAME] $LABEL query returned no data ($COUNT series matched). $HINT" >&2
    list_metrics_diag "$NAMESPACE" "$METRIC"
    FAILED=1
  else
    echo "OK: [$NAME] $LABEL (latest: $VALUE; $COUNT series returned — compare with desired_capacity)"
  fi
}

while IFS=$'\t' read -r NAME APP CHECK_CPU CHECK_MEMORY CHECK_DISK; do
  echo "--- Fleet entry '$NAME' (${APP_TAG_KEY}=$APP)"

  COUNT=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:${APP_TAG_KEY},Values=$APP" "Name=instance-state-name,Values=running" \
    --query "length(Reservations[].Instances[])" \
    --output text 2>/dev/null || echo "0")
  if [[ "$COUNT" == "0" || -z "$COUNT" ]]; then
    echo "WARNING: [$NAME] no running instances tagged ${APP_TAG_KEY}=$APP in $REGION. Check the launch template tag propagation." >&2
    FAILED=1
  else
    echo "OK: [$NAME] $COUNT running instance(s) tagged ${APP_TAG_KEY}=$APP."
  fi

  # Period 60 matches the capacity alarm's metric_query period. At 300 the SUM
  # would add five per-minute datapoints and report ~5x desired_capacity.
  check_query "$NAME" "GroupInServiceCapacity (tag telemetry)" \
    "SELECT SUM(GroupInServiceCapacity) FROM SCHEMA(\"AWS/AutoScaling\", AutoScalingGroupName) WHERE tag.${APP_TAG_KEY} = '$APP'" \
    "Enable CloudWatch 'resource tags on telemetry' and tag the ASG itself with ${APP_TAG_KEY}=$APP." \
    60 "AWS/AutoScaling" "GroupInServiceCapacity"

  if [[ "$CHECK_CPU" == "1" ]]; then
    check_query "$NAME" "CPUUtilization (EC2 tag telemetry)" \
      "SELECT AVG(CPUUtilization) FROM SCHEMA(\"AWS/EC2\", InstanceId) WHERE tag.${APP_TAG_KEY} = '$APP' GROUP BY InstanceId ORDER BY AVG() DESC" \
      "Enable CloudWatch 'resource tags on telemetry' for EC2 instances; if unavailable, the spec's fallback is the agent-side cpu_usage_idle metric." \
      300 "AWS/EC2" "CPUUtilization"
  fi

  # AppName here is the CWAgent metric dimension (fixed by the agent config),
  # not the resource tag key — do NOT swap in $APP_TAG_KEY.
  # Both checks are gated on disabled_alarms: the billing/dev example ships
  # disabled_alarms = ["memory"], so demanding the series unconditionally made
  # the preflight fail on a config that deliberately opts out of that alarm.
  if [[ "$CHECK_MEMORY" == "1" ]]; then
    check_query "$NAME" "mem_used_percent" \
      "SELECT AVG(mem_used_percent) FROM \"CWAgent\" WHERE AppName = '$APP' GROUP BY InstanceId ORDER BY AVG() DESC" \
      "Deploy the cwagent/ec2-java/ config (AppName dimension on the mem plugin)." \
      300 "CWAgent" "mem_used_percent"
  fi

  if [[ "$CHECK_DISK" == "1" ]]; then
    check_query "$NAME" "disk_used_percent" \
      "SELECT AVG(disk_used_percent) FROM \"CWAgent\" WHERE AppName = '$APP' AND path = '/' GROUP BY InstanceId ORDER BY AVG() DESC" \
      "Deploy the cwagent/ec2-java/ config (AppName dimension on the disk plugin, resources ['/'])." \
      300 "CWAgent" "disk_used_percent"
  fi
done <<< "$ENTRIES"

exit "$FAILED"
