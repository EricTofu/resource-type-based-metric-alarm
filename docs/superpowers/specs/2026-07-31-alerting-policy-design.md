# Alerting Policy — what pages, what warns, what stays on a dashboard

**Date:** 2026-07-31
**Status:** design, approved in conversation; implementation plan not yet written
**Supersedes:** the JVM-alarm decisions in `2026-07-30-module-identity-boundaries-design.md`
(that spec's blocking verify item 2 is resolved here, and `gc_time` is reinstated in a
different form)

## Problem

The repo grew alarm-by-alarm: 13 modules, 40 alarms, severities assigned per module as
each was written. Nobody had classified the set as a whole against what the severity
tiers actually *do*. The result, measured before this design:

| tier | count | contents |
|---|---|---|
| CRIT | 3 | ec2 `status_check`, `status_check_ebs`; rds `engine_uptime` |
| ERROR | 10 | alb `unhealthy_host`; asg capacity ×2; cloudfront `error_5xx`; elasticache ×2; lambda `errors`; opensearch `cpu` / `jvm_memory` / `old_gen_jvm_memory` |
| WARN | 27 | every cpu / memory / disk / latency / storage / 5xx / bounce-rate alarm, plus jmx `heap_used` |

(Counts are of alarm *resources*, not severity-map keys — the asg module's `fleet_*`
alarms reuse the legacy keys, so a key can back two alarms.)

Two defects follow from that distribution:

1. **The pager is inverted.** CRIT is the only tier that wakes a human. Today that means
   an EC2 status check pages, while `target_5xx` (users receiving errors) is WARN — a
   digest — and `unhealthy_host` (every target down) is ERROR — chat, working hours. A
   total outage at 02:00 pages nobody; one instance's status check does.
2. **WARN is a landfill.** Three-quarters of all alarms route to one topic, so that topic
   is either ignored or exhausting. Either way it is not a control surface.

A second trigger: `cwagent/ec2-java/` now publishes JVM and host telemetry that no alarm
consumed, and the question "should heap/GC alarm at all?" had no policy to answer it
against.

## Routing contract (the input everything else derives from)

| tier | destination | response expectation |
|---|---|---|
| CRIT | pager / phone | wakes a human, any hour |
| ERROR | chat | acted on during working hours |
| WARN | digest / low-attention feed | read deliberately; never urgent |

This contract is assumed, not created, by this design. If it changes, this whole
classification must be re-derived.

## Principles

1. **Page on symptoms and liveness only** — things that need no hypothesis to interpret.
2. **Warn on causes**, including causes believed to precede symptoms, until their lead
   time is *measured*.
3. **Dashboard everything whose value is diagnostic** — useful while investigating, never
   as a notification.
4. **A signal earns promotion to CRIT with evidence**, not with an argument. See
   "Promotion criterion".
5. **Verify a metric's shape before designing math on it.** See "Metric shape rule".

## Classification

### CRIT — pages (9)

| alarm | module | change |
|---|---|---|
| `status_check`, `status_check_ebs` | ec2 | unchanged |
| `engine_uptime` | rds | unchanged |
| `in_service_capacity`, `fleet_in_service_capacity` | asg | promote from ERROR |
| `unhealthy_host` | alb | promote from ERROR |
| `target_5xx`, `elb_5xx` | alb | promote from WARN — fixes the inversion |
| `target_response_time` | alb | **re-enable** (currently commented out) + promote from WARN |

Every entry is "users are being hurt right now" or "the thing is gone". No JVM metric is
in this tier.

### ERROR — chat (14)

- jmx `gc_time`, `heap_used` — candidate leading indicators, see "JVM signals"
- rds `free_storage`, `freeable_memory`, `write_latency`
- elasticache `cpu`, `memory` — unchanged
- lambda `errors` — unchanged
- s3 `replication_failed` — data-durability risk
- cloudfront `error_5xx` — unchanged (already ERROR)
- opensearch `cpu`, `jvm_memory`, `old_gen_jvm_memory` — unchanged; plus `free_storage`,
  promoted from WARN so the four move together. These are AWS-recommended defaults on a
  cluster that is not heavily loaded in production; kept at ERROR deliberately rather than
  for consistency with our own JVM signals, which are held at ERROR for a different reason
  (unvalidated lead time).

### WARN — digest (19)

ec2 and asg-fleet `cpu` / `memory` / `disk`; efs `throughput_util`; rds `cpu` /
`database_connections` / `read_latency` / `acu_utilization` / `serverless_capacity`;
cloudfront `origin_latency`; ses `bounce_rate`; lambda `duration` / `throttles` /
`concurrency`; apigateway `error_5xx`; s3 `error_5xx`.

cloudfront `error_5xx` stays at **ERROR**, its current value — untouched because it was
never discussed. rds `volume_bytes_used` and cloudfront `error_4xx` / `cache_hit_rate` are
commented out in their modules and are not part of this classification.

`apigateway error_5xx` stays WARN **because the customer-facing path is covered by a
synthetic canary alarm that fires on any non-200**. That canary lives outside this repo.
Do not "fix" this WARN without checking the canary still exists.

### Dashboard only — no alarm

JVM: classes loaded, non-heap, per-collector GC detail. Host: swap, netstat, processes,
ethtool, diskio, net — all collected by `cwagent/ec2-java/`, none alarmed.

Resulting shape: **9 CRIT / 14 ERROR / 19 WARN** = 42 alarms, against 3 / 10 / 27 = 40
today. The two additions are `gc_time` (reinstated) and `target_response_time`
(re-enabled); nothing is deleted.

## JVM signals

### `gc_time` — reinstated, in a corrected form

The agent applies a `cumulativetodelta/jmx` processor before publishing (visible in the
translated pipeline at `/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.yaml`,
with `initial_value: 2` dropping the first point). Confirmed empirically over a 3-hour
span: `jvm_gc_collections_elapsed` rises to ~30 and returns to 0 rather than climbing.

**The metric in the `CWAgent` namespace is therefore already milliseconds of GC per
60-second collection interval** — the exact quantity the alarm wanted. It needs no metric
math:

```sql
SELECT SUM(jvm_gc_collections_elapsed) FROM "CWAgent"
WHERE AppName = '<app_name>' [AND ProcessGroupName = '<process_group>']
GROUP BY InstanceId ORDER BY SUM() DESC
```

- `SUM` totals across the per-collector `name` series within each instance.
- Threshold 6000 ms per minute = 10% of wall clock in GC; not arbitrary — it is the
  standard GC-overhead heuristic.
- `period=60`, `evaluation_periods=5`, `datapoints_to_alarm=5`: five consecutive minutes,
  so a single stop-the-world burst does not fire it.
- `treat_missing_data=notBreaching`; "the host is gone" belongs to ec2 `status_check` and
  the asg capacity watchdog, both missing-data=breaching.

The previous `DIFF(q1)` form was wrong twice: rejected by `PutMetricAlarm` (metric math
cannot wrap a multi-series query), *and* semantically wrong — differencing an already-
differenced series measures the change in GC time, i.e. acceleration. The
"JVM restart resets the counter → negative `DIFF` → fails safe" reasoning guarded against
a reset that never reaches CloudWatch. The API error caught a modelling error.

This is also the **best-evidenced JVM signal available**: "full GC running again and again
yet reclaiming nothing" is what was actually observed during the incident described below.

### `heap_used` — kept, window lengthened

Instantaneous heap is a poor threshold: sampled every 60s it catches a random phase of the
collection sawtooth, and a healthy JVM legitimately sits near `-Xmx` just before a
collection. What distinguishes a sick JVM is that heap *stays* high because the post-GC
live set is high.

Duration substitutes for the post-GC sampling CloudWatch cannot do: **90% of
`heap_max_bytes` for 10 consecutive minutes** — `period=60`, `evaluation_periods=10`,
`datapoints_to_alarm=10`, both overridable per entry as EFS already does for its trend
alarm — replacing the current 3-minute window. Default `heap_threshold` rises 85 → 90 to
match the longer window. `heap_max_bytes` comes from `scripts/resolve_heap_max.sh`, not by hand.

### `thread_count` — deferred, not implemented

Rejected for now on honest grounds: thread count was **not being collected during the
incident**, so "threads piled up" is a reconstruction of the mechanism, not an observation.
A GC spiral sustains itself once the live set stops shrinking, whether 30 threads or 300
are waiting. Building a pager on that inference would be paging on a hypothesis.

Recorded for revival if the reproduction (below) shows it moving first. If revived, note
the design constraint found during this work: a *bounded* pool (Tomcat `maxThreads`)
plateaus rather than climbing, so any threshold must sit below the ceiling or it fires only
once the app is already refusing work.

### Anomaly detection — rejected for the fleet case

Three independent reasons: the model is per metric + statistic and its alarm is still a
`PutMetricAlarm`, so a `GROUP BY InstanceId` query cannot back one (per-instance detectors
would re-couple to instance churn); the model re-trains continuously, so recurring peak-hour
saturation is learned as normal exactly where the alarm should be loudest; and thread count
has a physical ceiling, making "approaching the limit" the real question rather than "is
this unusual". Statistical bands earn their keep where no physical limit exists.

## EFS — demoted, not promoted

The incident that motivated this work: **EFS (Bursting mode) throttled → threads blocked on
I/O → work arrived faster than it drained → heap filled with in-flight state → full GC
looped reclaiming nothing → app alive but unusable.** Elapsed: under 30 minutes.

The file system was moved to **Elastic throughput** afterwards. Elastic has no burst
credits, so the precise trigger cannot recur — it was fixed at the resource, which beats
any alarm.

Therefore EFS keeps only its existing 6-hour `throughput_util` trend alarm at WARN,
reinterpreted as a cost-and-capacity signal rather than an outage predictor. No short-window
EFS alarm is added. Note explicitly: **that 6h alarm could not have caught the incident**
(6 hours sustained vs. a sub-30-minute cascade); it is not, and should not be treated as,
protection against a repeat.

Elastic still has per-file-system throughput quotas, so a runaway workload can hit a
ceiling. That path produces the same cascade and is covered by the JVM signals.

## Promotion criterion

A candidate signal moves from ERROR to CRIT when it is observed to precede user-visible
symptoms by enough time to act, in a real incident *or* a reproduction, **with the measured
lead time written into this spec**. Argument alone does not promote.

### Reproduction experiment (how to get that evidence)

In a lower environment: introduce artificial I/O latency on the mount the app blocks
against, drive representative traffic, and record which series moves first and by how much —
GC time, heap, threads, latency, 5xx. Half a day of work; it converts the entire question
from argument to measurement, and yields the lead time the criterion requires. The JMX
instrumentation that made this experiment possible was the original point of the JMX work,
before it drifted toward alarming.

## CloudWatch constraints this design is built on

1. **Any expression backing an alarm must return a single time series** — except a Metrics
   Insights expression carrying `ORDER BY`, whose series become individual alarm
   contributors (alarm enters ALARM when any one breaches).
2. **Metric math cannot wrap a multi-series query.** `DIFF(q1)` / `RATE(q1)` over a
   `GROUP BY` query is rejected regardless of what `q1` contains.
3. Consequence: a fleet-wide alarm is only possible on a metric that is *directly*
   alarmable as a gauge. Anything needing a derived rate must be derived before CloudWatch
   sees it — which the agent's `cumulativetodelta` already does for JMX.

### Metric shape rule

Confirm a metric's temporality (gauge / cumulative / delta) against the *agent's translated
pipeline* and against real data before designing math on it. Graphing a query in
`GetMetricData` proves nothing about whether it can back an alarm; create one throwaway
alarm by hand first. Both failures in the previous JMX design trace to skipping this.

## Open questions

- **Collection-interval coupling.** "ms per interval" equals "ms per minute" only while
  `metrics_collection_interval` is 60. At 30 every GC threshold silently halves in meaning.
  Record this in `cwagent/ec2-java/README.md` beside the dimension contract.
- **PromQL ingestion path.** CloudWatch PromQL alarms treat *any* returned series as
  breaching, which would allow fleet-wide statistical bands with no hardcoded threshold.
  Query Studio is documented as covering "metrics ingested via OTLP and AWS vended
  metrics"; whether `PutMetricData` custom metrics in the `CWAgent` namespace qualify is
  unconfirmed. Test: Query Studio → PromQL → `{"jvm_threads_count"}`, with an AWS-vended
  metric as a positive control.
- **Preflight fidelity.** `check_jmx_metrics.sh` and `check_asg_fleet_metrics.sh` build
  their own copies of the alarm queries and now lack `ORDER BY`. No preflight could have
  caught the multi-series rejection — `GetMetricData` accepts what `PutMetricAlarm`
  refuses — so this is about keeping the "runs the alarms' actual SELECTs" claim true.

## Out of scope

Adding new resource types; the synthetic canary (lives outside this repo); dashboard
layout changes beyond what already exists; the ASG/JMX identity model, which is settled by
the 2026-07-30 spec.

## Implementation surface

- `modules/cloudwatch/metrics-alarm/jmx/`: reinstate `gc_time` as the gauge query above;
  make `heap_used`'s evaluation window overridable and default it long; restore
  `gc_time_threshold_ms` and the `gc_time` id in `disabled_alarms` validation.
- `modules/cloudwatch/metrics-alarm/alb/`: uncomment `target_response_time`; severity
  changes.
- Severity reclassification is per-module edits to the `default_severities` locals, plus
  the leaf/module docs that quote them.
- `stacks/projects/billing/dev/`: example files and `variables.tf` for any new inputs.
- Docs: CLAUDE.md severity/JMX sections, `cwagent/ec2-java/README.md` interval note.
