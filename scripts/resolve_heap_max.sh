#!/usr/bin/env bash
#------------------------------------------------------------------------------
# resolve_heap_max.sh — emit a paste-ready heap_max_bytes for a JMX entry.
#
# Reads the value the JVM itself reports (jvm_memory_heap_max, published by the
# cwagent/ec2-java/ config) instead of making you derive it from -Xmx or from
# -XX:MaxRAMPercentage x instance RAM. MemoryMXBean sums the heap pools and on
# some collectors excludes one survivor space, so the reported max is typically
# a little under -Xmx: the observed number is the one the alarm threshold should
# come from, and it is what scripts/check_jmx_metrics.sh reconciles against
# (+/-10%). Paste this output and that check passes by construction.
#
# Unlike check_jmx_metrics.sh this takes the AppName directly rather than
# parsing a config file, so it can be run BEFORE the entry exists.
#
# The query groups by instance instead of taking one MAX across the group:
#
#   SELECT MAX(jvm_memory_heap_max) FROM "CWAgent"
#   WHERE AppName = '<app>' [AND ProcessGroupName = '<pg>'] GROUP BY InstanceId
#
# so a group whose members do NOT share a heap size is reported rather than
# collapsed into a single number. That case cannot be covered by one entry: the
# heap alarm is a single byte threshold compared against every instance's
# series, so the smallest-heap host would be under-alarmed (silently green — the
# failure class the JMX module exists to remove). Split it into one AppName per
# heap size instead.
#
# Requires cloudwatch:GetMetricData, plus cloudwatch:ListMetrics for the no-data
# diagnostic. python3 is used for JSON quoting/parsing only.
#
# Usage:
#   scripts/resolve_heap_max.sh --app-name live --profile <aws-profile>
#                               --region ap-northeast-1
#                               [--process-group chat-server-tomcat]
#                               [--name live] [--hours 1]
#
# --profile and --region are required and are NOT defaulted from the
# environment: the emitted heap_max_bytes gets committed, so which account and
# region it was read from must be explicit in the command, not inherited from
# whatever AWS_PROFILE happened to be exported.
#
# Exit codes:
#   0  value emitted
#   1  no data, or the AWS call failed
#   2  the group's instances disagree on heap size by more than 10%
#------------------------------------------------------------------------------

set -euo pipefail

APP=""
PROCESS_GROUP=""
NAME=""
REGION=""
PROFILE=""
HOURS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)      APP="$2"; shift 2 ;;
    --process-group) PROCESS_GROUP="$2"; shift 2 ;;
    --name)          NAME="$2"; shift 2 ;;
    --region)        REGION="$2"; shift 2 ;;
    --profile)       PROFILE="$2"; shift 2 ;;
    --hours)         HOURS="$2"; shift 2 ;;
    -h|--help)       sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

MISSING=()
[[ -n "$APP" ]]     || MISSING+=(--app-name)
[[ -n "$PROFILE" ]] || MISSING+=(--profile)
[[ -n "$REGION" ]]  || MISSING+=(--region)

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: missing required argument(s): ${MISSING[*]}" >&2
  echo "Usage: $0 --app-name <AppName> --profile <profile> --region <region> [--process-group <pg>] [--name <label>] [--hours <n>]" >&2
  exit 1
fi

# Shared by every call below, so the profile/region pair can never be applied to
# the query and forgotten on the diagnostic — which would silently read the two
# from different accounts.
AWS_ARGS=(--profile "$PROFILE" --region "$REGION")

if ! [[ "$HOURS" =~ ^[0-9]+$ ]] || [[ "$HOURS" -lt 1 ]]; then
  echo "ERROR: --hours must be a positive integer." >&2
  exit 1
fi

# Metrics Insights only sees series with data in roughly the last 3 hours, so a
# wider window buys nothing and just hides how stale the reading is.
if [[ "$HOURS" -gt 3 ]]; then
  echo "NOTE: Metrics Insights looks back roughly 3h; clamping --hours $HOURS to 3." >&2
  HOURS=3
fi

# Label defaults to the AppName — in a config entry `name` is a free label and
# is most often the same string.
[[ -n "$NAME" ]] || NAME="$APP"

json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

PG_FILTER=""
[[ -z "$PROCESS_GROUP" ]] || PG_FILTER=" AND ProcessGroupName = '$PROCESS_GROUP'"

QUERY="SELECT MAX(jvm_memory_heap_max) FROM \"CWAgent\" WHERE AppName = '$APP'$PG_FILTER GROUP BY InstanceId"

START=$(date -u -d "$HOURS hours ago" '+%Y-%m-%dT%H:%M:%SZ')
END=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

echo "Profile: $PROFILE" >&2
echo "Region:  $REGION" >&2
echo "Window:  $START .. $END" >&2
echo "Query:   $QUERY" >&2
echo >&2

CLI_ERR=$(mktemp)
# The response goes to a file, not a pipe: the python below is itself fed on
# stdin by its heredoc, so it cannot also read the payload from there.
RAW_FILE=$(mktemp)
trap 'rm -f "$CLI_ERR" "$RAW_FILE"' EXIT

RC=0
aws cloudwatch get-metric-data \
  "${AWS_ARGS[@]}" \
  --start-time "$START" \
  --end-time "$END" \
  --metric-data-queries "[{\"Id\":\"q1\",\"Period\":60,\"Expression\":$(json_str "$QUERY")}]" \
  --output json >"$RAW_FILE" 2>"$CLI_ERR" || RC=$?

if [[ $RC -ne 0 ]]; then
  echo "ERROR: aws cloudwatch get-metric-data exited $RC — this is a failed call, not an empty result:" >&2
  sed 's/^/    /' "$CLI_ERR" >&2
  echo "  Hint: this needs cloudwatch:GetMetricData in the region above." >&2
  exit 1
fi

# Reports per instance, then emits the YAML. Values[0] is the most recent
# datapoint (get-metric-data returns TimestampDescending by default). Exit 3
# means "no series had data" so the caller can add the list-metrics diagnostic.
set +e
python3 - "$RAW_FILE" "$NAME" "$APP" "$PROCESS_GROUP" <<'PY'
import json, sys

raw_file, label, app, process_group = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(raw_file) as fh:
    results = json.load(fh).get("MetricDataResults", [])

# One (instance, latest heap max) pair per series that actually reported. A
# series with an empty Values array is normal: Insights matches instances that
# had data in the last ~3h, which is wider than this script's window, so a host
# terminated in between comes back present-but-empty.
series = sorted(
    (r.get("Label") or "?", float(r["Values"][0]))
    for r in results
    if r.get("Values")
)

if not series:
    print(f"No data: {len(results)} series matched, none with a datapoint in the window.",
          file=sys.stderr)
    sys.exit(3)

GIB = 1024 ** 3
for instance, value in series:
    print(f"  {instance}: {int(round(value))} bytes ({value / GIB:.2f} GiB)", file=sys.stderr)
print(file=sys.stderr)

lo = min(v for _, v in series)
hi = max(v for _, v in series)
spread = (hi - lo) / hi

# 10% is not arbitrary: it is the tolerance check_jmx_metrics.sh reconciles
# heap_max_bytes against, so beyond it no single committed value can satisfy
# every instance in the group.
if spread > 0.10:
    print(f"ERROR: the {len(series)} instances under AppName='{app}' disagree on heap size "
          f"by {spread * 100:.1f}% (smallest {lo / GIB:.2f} GiB, largest {hi / GIB:.2f} GiB).",
          file=sys.stderr)
    print("  One entry cannot cover them: the heap alarm is a single byte threshold applied to "
          "every instance's series, so the smallest-heap host would never breach it (fails green).",
          file=sys.stderr)
    print("  Give each heap size its own AppName (separate agent config / entry), then re-run "
          "this per AppName.", file=sys.stderr)
    sys.exit(2)

if spread > 0.01:
    print(f"WARNING: heap sizes vary by {spread * 100:.1f}% across {len(series)} instances "
          f"(within the +/-10% preflight tolerance). Emitting the SMALLEST, so the threshold "
          f"is the conservative one — every instance can reach it.", file=sys.stderr)
    print(file=sys.stderr)

# The smallest observed max: with a larger value, a host with a smaller heap can
# never reach the threshold and its alarm sits green through an OOM.
chosen = int(lo)

print(f"    # {label}: observed jvm_memory_heap_max across {len(series)} instance(s)")
print(f"    - name:           {label}")
print(f"      app_name:       {app}")
if process_group:
    print(f"      process_group:  {process_group}")
print(f"      heap_max_bytes: {chosen}     # {chosen / GIB:.2f} GiB")
PY
PY_RC=$?
set -e

if [[ $PY_RC -eq 3 ]]; then
  # Separate "the metric does not exist" from "the filter matched nothing" —
  # --recently-active PT3H is the same window Metrics Insights itself can see.
  COUNT=$(aws cloudwatch list-metrics \
    "${AWS_ARGS[@]}" \
    --namespace CWAgent \
    --metric-name jvm_memory_heap_max \
    --recently-active PT3H \
    --query "length(Metrics)" \
    --output text 2>/dev/null) || COUNT=""

  if [[ -z "$COUNT" ]]; then
    echo "  Diagnostic: list-metrics --recently-active PT3H could not be run (needs cloudwatch:ListMetrics)." >&2
  elif [[ "$COUNT" == "0" ]]; then
    echo "  Diagnostic: 0 recently-active jvm_memory_heap_max series in CWAgent — the metric is absent." >&2
    echo "  Deploy the cwagent/ec2-java/ config (JVM names renamed to snake_case) and expose the JMX endpoint." >&2
  else
    echo "  Diagnostic: $COUNT recently-active jvm_memory_heap_max series exist in CWAgent — the metric is there," >&2
    echo "  so it is the filter that matched nothing. Check AppName='$APP'${PROCESS_GROUP:+ / ProcessGroupName='$PROCESS_GROUP'} against the agent config." >&2
  fi
  exit 1
fi

exit $PY_RC
