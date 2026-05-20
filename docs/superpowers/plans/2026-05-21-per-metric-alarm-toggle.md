# Per-Metric Alarm Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let each project skip individual metric alarms per resource via an opt-out `disabled_alarms` set in `overrides`, across all 11 CloudWatch alarm modules.

**Architecture:** Add `disabled_alarms = optional(set(string), [])` to each module's `overrides` object plus a validation block listing that module's valid metric IDs. Each per-resource `aws_cloudwatch_metric_alarm` filters disabled metrics out of its `for_each`. Lambda's account-level concurrency alarm gets a separate module-level `concurrency_alarm_enabled` flag. S3 replication stays a separate opt-in gate. The single project stack (`billing/dev`) re-declares the resource types, so it gets the `disabled_alarms` field too (no validation — the module validates). Preflight scripts skip a resource's metric when it is disabled.

**Tech Stack:** Terraform >= 1.10, hashicorp/aws >= 5.0, bash + python3 preflight scripts.

**Spec:** `docs/superpowers/specs/2026-05-21-per-metric-alarm-toggle-design.md`

---

## Shared Edit Patterns (referenced by every module task)

Three concrete edits recur. Each task below states only its module-specific values (paths, metric-ID list, resource labels); apply these patterns with those values.

**Pattern A — add the field** to the `overrides` object in the module's `variables.tf`, as the last attribute before the closing `}), {})`:

```hcl
      disabled_alarms = optional(set(string), [])
```

**Pattern B — add a validation block** to the `resources` variable (after the existing validation blocks, before the variable's closing `}`). Substitute the module's metric-ID list:

```hcl
  validation {
    condition = alltrue([
      for r in var.resources : alltrue([
        for m in try(r.overrides.disabled_alarms, []) :
        contains(["<ID1>", "<ID2>"], m)
      ])
    ])
    error_message = "overrides.disabled_alarms entries must be a subset of: <ID1>, <ID2>"
  }
```

> Convention note: keep `try(r.overrides.disabled_alarms, [])` / `try(v.overrides.disabled_alarms, [])` even though the `optional(..., [])` default makes the value always-present. Every existing alarm in these modules accesses overrides via `try(each.value.overrides.X, ...)`, so matching that style keeps each file internally consistent. Error messages follow the existing `overrides.<field> ...` phrasing.

**Pattern C — filter the alarm's `for_each`.** Replace the per-resource alarm's existing `for_each = local.<map>` with the filtered form. `<metric_id>` is the metric ID for that specific alarm resource (see each task's label→ID table):

```hcl
  for_each = {
    for k, v in local.<map> : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "<metric_id>")
  }
```

> Note on defaults: `overrides` defaults to `{}` and `disabled_alarms` defaults to `[]`, so `try(v.overrides.disabled_alarms, [])` is always a set; the `try` is defensive only. `contains()` accepts a set.

**Standard per-module test (run where the `terraform` binary exists; no AWS creds needed):**

```bash
cd modules/cloudwatch/metrics-alarm/<type>
terraform init -backend=false && terraform validate
```
Expected: `Success! The configuration is valid.`

Then from repo root: `terraform fmt -recursive` (expected: no files reformatted, or only the file you edited).

---

## Task 1: EC2 module (canonical)

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/ec2/variables.tf` (overrides object + validation)
- Modify: `modules/cloudwatch/metrics-alarm/ec2/main.tf` (4 alarm `for_each` blocks)

Local map: `local.ec2_resources`. Metric IDs = resource labels (they match here).

Label → metric_id: `status_check`→`status_check`, `status_check_ebs`→`status_check_ebs`, `cpu`→`cpu`, `memory`→`memory`.

- [ ] **Step 1: Add the field (Pattern A).** In `variables.tf`, add `disabled_alarms = optional(set(string), [])` as the last attribute of the `overrides` object so it reads:

```hcl
    overrides = optional(object({
      severity         = optional(string)
      description      = optional(string)
      cpu_threshold    = optional(number)
      memory_threshold = optional(number)
      disabled_alarms  = optional(set(string), [])
    }), {})
```

- [ ] **Step 2: Add the validation block (Pattern B).** In `variables.tf`, after the existing `memory_threshold` validation block and before the `resources` variable's closing brace:

```hcl
  validation {
    condition = alltrue([
      for r in var.resources : alltrue([
        for m in try(r.overrides.disabled_alarms, []) :
        contains(["status_check", "status_check_ebs", "cpu", "memory"], m)
      ])
    ])
    error_message = "ec2 disabled_alarms must be a subset of: status_check, status_check_ebs, cpu, memory"
  }
```

- [ ] **Step 3: Filter all four alarms (Pattern C).** In `main.tf`, for each of the four `aws_cloudwatch_metric_alarm` blocks (`status_check`, `status_check_ebs`, `cpu`, `memory`), replace `for_each = local.ec2_resources` with the filtered form using that block's metric_id. Example for the `memory` block:

```hcl
resource "aws_cloudwatch_metric_alarm" "memory" {
  for_each = {
    for k, v in local.ec2_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "memory")
  }
```

Do the same for `status_check` (`"status_check"`), `status_check_ebs` (`"status_check_ebs"`), and `cpu` (`"cpu"`).

- [ ] **Step 4: Validate.** Run the standard per-module test (`type` = `ec2`). Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit.**

```bash
git add modules/cloudwatch/metrics-alarm/ec2/variables.tf modules/cloudwatch/metrics-alarm/ec2/main.tf
git commit -m "feat(metrics): add disabled_alarms toggle to ec2 module"
```

---

## Task 2: ALB module

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/alb/variables.tf`
- Modify: `modules/cloudwatch/metrics-alarm/alb/main.tf`

Local map: `local.alb_resources`. Metric IDs = resource labels.

Labels/IDs: `elb_5xx`, `target_5xx`, `unhealthy_host`, `target_response_time`.

- [ ] **Step 1: Pattern A** — add `disabled_alarms = optional(set(string), [])` to the `overrides` object in `variables.tf`.

- [ ] **Step 2: Pattern B** — add validation block with id list `["elb_5xx", "target_5xx", "unhealthy_host", "target_response_time"]` and matching error message.

- [ ] **Step 3: Pattern C** — filter `for_each` on all four alarm blocks (`elb_5xx`, `target_5xx`, `unhealthy_host`, `target_response_time`), each using its own label as `<metric_id>`, replacing `local.alb_resources`.

- [ ] **Step 4: Validate** — standard per-module test (`type` = `alb`).

- [ ] **Step 5: Commit.**

```bash
git add modules/cloudwatch/metrics-alarm/alb/variables.tf modules/cloudwatch/metrics-alarm/alb/main.tf
git commit -m "feat(metrics): add disabled_alarms toggle to alb module"
```

---

## Task 3: CloudFront module + behavioral test

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/cloudfront/variables.tf`
- Modify: `modules/cloudwatch/metrics-alarm/cloudfront/main.tf`
- Create: `modules/cloudwatch/metrics-alarm/cloudfront/tests/disabled_alarms.tftest.hcl`

Local map: `local.cloudfront_resources` (keyed by `distribution_id`). Metric IDs = resource labels: `error_4xx`, `error_5xx`, `origin_latency`, `cache_hit_rate`.

- [ ] **Step 1: Pattern A** — add `disabled_alarms = optional(set(string), [])` to the `overrides` object in `variables.tf`.

- [ ] **Step 2: Pattern B** — add validation block with id list `["error_4xx", "error_5xx", "origin_latency", "cache_hit_rate"]` and matching error message.

- [ ] **Step 3: Pattern C** — filter `for_each` on all four alarm blocks, replacing `local.cloudfront_resources`, each with its own label as `<metric_id>`.

- [ ] **Step 4: Validate** — standard per-module test (`type` = `cloudfront`).

- [ ] **Step 5: Write the behavioral test** (no AWS creds needed — `mock_provider` mocks all AWS data sources/resources). Create `tests/disabled_alarms.tftest.hcl`:

```hcl
mock_provider "aws" {}

variables {
  project = "test"
  sns_topic_arns = {
    WARN  = "arn:aws:sns:us-east-1:123456789012:warn"
    ERROR = "arn:aws:sns:us-east-1:123456789012:error"
    CRIT  = "arn:aws:sns:us-east-1:123456789012:crit"
  }
}

run "all_alarms_by_default" {
  command = plan
  variables {
    resources = [
      { distribution_id = "E123ABC" }
    ]
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.error_4xx) == 1
    error_message = "error_4xx should be created by default"
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.cache_hit_rate) == 1
    error_message = "cache_hit_rate should be created by default"
  }
}

run "disabled_metric_skipped" {
  command = plan
  variables {
    resources = [
      {
        distribution_id = "E123ABC"
        overrides       = { disabled_alarms = ["cache_hit_rate"] }
      }
    ]
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.cache_hit_rate) == 0
    error_message = "cache_hit_rate should be skipped when disabled"
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.error_4xx) == 1
    error_message = "non-disabled alarms should remain"
  }
}

run "bogus_metric_id_rejected" {
  command = plan
  variables {
    resources = [
      {
        distribution_id = "E123ABC"
        overrides       = { disabled_alarms = ["not_a_metric"] }
      }
    ]
  }
  expect_failures = [var.resources]
}
```

- [ ] **Step 6: Run the test** (where `terraform` >= 1.10 is installed):

```bash
cd modules/cloudwatch/metrics-alarm/cloudfront
terraform init -backend=false && terraform test
```
Expected: all three `run` blocks pass (`3 passed, 0 failed`). If `terraform` is unavailable in this environment, defer this step to CI / the work machine and note it.

- [ ] **Step 7: Commit.**

```bash
git add modules/cloudwatch/metrics-alarm/cloudfront/variables.tf modules/cloudwatch/metrics-alarm/cloudfront/main.tf modules/cloudwatch/metrics-alarm/cloudfront/tests/disabled_alarms.tftest.hcl
git commit -m "feat(metrics): add disabled_alarms toggle to cloudfront module + tftest"
```

---

## Task 4: OpenSearch module

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/opensearch/variables.tf`
- Modify: `modules/cloudwatch/metrics-alarm/opensearch/main.tf`

Local map: `local.opensearch_resources`.

> **Naming caveat:** the metric IDs match the `default_severities` keys, NOT the resource labels for one alarm. The resource labeled `old_gen_jvm_memory` uses metric ID `old_gen_jvm`. Label → metric_id: `cpu`→`cpu`, `jvm_memory`→`jvm_memory`, `old_gen_jvm_memory`→`old_gen_jvm`, `free_storage`→`free_storage`.

- [ ] **Step 1: Pattern A** — add `disabled_alarms = optional(set(string), [])` to the `overrides` object in `variables.tf`.

- [ ] **Step 2: Pattern B** — add validation block with id list `["cpu", "jvm_memory", "old_gen_jvm", "free_storage"]` and matching error message.

- [ ] **Step 3: Pattern C** — filter `for_each` on all four alarm blocks, replacing `local.opensearch_resources`. Use metric IDs per the table above — note the `old_gen_jvm_memory` resource gets `"old_gen_jvm"`:

```hcl
resource "aws_cloudwatch_metric_alarm" "old_gen_jvm_memory" {
  for_each = {
    for k, v in local.opensearch_resources : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "old_gen_jvm")
  }
```

- [ ] **Step 4: Validate** — standard per-module test (`type` = `opensearch`).

- [ ] **Step 5: Commit.**

```bash
git add modules/cloudwatch/metrics-alarm/opensearch/variables.tf modules/cloudwatch/metrics-alarm/opensearch/main.tf
git commit -m "feat(metrics): add disabled_alarms toggle to opensearch module"
```

---

## Task 5: ElastiCache module

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/elasticache/variables.tf`
- Modify: `modules/cloudwatch/metrics-alarm/elasticache/main.tf`

Local map: `local.elasticache_resources`. Labels/IDs: `cpu`, `memory`.

- [ ] **Step 1: Pattern A** — add the field to `overrides`.
- [ ] **Step 2: Pattern B** — validation id list `["cpu", "memory"]`.
- [ ] **Step 3: Pattern C** — filter `for_each` on the `cpu` and `memory` alarm blocks, replacing `local.elasticache_resources`.
- [ ] **Step 4: Validate** — standard per-module test (`type` = `elasticache`).
- [ ] **Step 5: Commit.**

```bash
git add modules/cloudwatch/metrics-alarm/elasticache/variables.tf modules/cloudwatch/metrics-alarm/elasticache/main.tf
git commit -m "feat(metrics): add disabled_alarms toggle to elasticache module"
```

---

## Task 6: RDS module

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/rds/variables.tf`
- Modify: `modules/cloudwatch/metrics-alarm/rds/main.tf`

Local maps: most alarms use `local.all_instances`; `acu_utilization` and `serverless_capacity` use `{ for k, v in local.all_instances : k => v if v.serverless }`.

Active metric IDs (labels, excluding the commented-out `volume_bytes_used`): `freeable_memory`, `cpu`, `database_connections`, `free_storage`, `engine_uptime`, `read_latency`, `write_latency`, `acu_utilization`, `serverless_capacity`.

> Cluster note: `overrides` propagates to expanded cluster members in the cluster-expansion `local` block, so a cluster's `disabled_alarms` automatically applies to every member instance. No extra work needed.

- [ ] **Step 1: Pattern A** — add `disabled_alarms = optional(set(string), [])` to the `overrides` object in `variables.tf`.

- [ ] **Step 2: Pattern B** — add validation block with id list `["freeable_memory", "cpu", "database_connections", "free_storage", "engine_uptime", "read_latency", "write_latency", "acu_utilization", "serverless_capacity"]` and matching error message.

- [ ] **Step 3: Filter the seven non-serverless alarms.** For `freeable_memory`, `cpu`, `database_connections`, `free_storage`, `engine_uptime`, `read_latency`, `write_latency`, replace `for_each = local.all_instances` with (using each block's label as `<metric_id>`):

```hcl
  for_each = {
    for k, v in local.all_instances : k => v
    if !contains(try(v.overrides.disabled_alarms, []), "<metric_id>")
  }
```

- [ ] **Step 4: Filter the two serverless alarms.** For `acu_utilization` and `serverless_capacity`, AND the disabled-check onto the existing `if v.serverless`:

```hcl
resource "aws_cloudwatch_metric_alarm" "acu_utilization" {
  for_each = {
    for k, v in local.all_instances : k => v
    if v.serverless && !contains(try(v.overrides.disabled_alarms, []), "acu_utilization")
  }
```

And `serverless_capacity` with `"serverless_capacity"`.

- [ ] **Step 5: Validate** — standard per-module test (`type` = `rds`).

- [ ] **Step 6: Commit.**

```bash
git add modules/cloudwatch/metrics-alarm/rds/variables.tf modules/cloudwatch/metrics-alarm/rds/main.tf
git commit -m "feat(metrics): add disabled_alarms toggle to rds module"
```

---

## Task 7: Lambda module (per-resource duration + module-level concurrency)

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/lambda/variables.tf` (overrides field + validation + new `concurrency_alarm_enabled` variable)
- Modify: `modules/cloudwatch/metrics-alarm/lambda/main.tf` (`duration` for_each + `concurrency` count)

Local map: `local.lambda_resources`. Per-resource metric ID: `duration`. Account-level `concurrency` is gated by a module variable, NOT by `disabled_alarms`.

- [ ] **Step 1: Pattern A** — add `disabled_alarms = optional(set(string), [])` to the `overrides` object in `variables.tf`.

- [ ] **Step 2: Pattern B** — add validation block with id list `["duration"]` and error message `"overrides.disabled_alarms entries must be a subset of: duration"`.

- [ ] **Step 3: Add the concurrency variable.** In `variables.tf`, add a new top-level variable:

```hcl
variable "concurrency_alarm_enabled" {
  description = "Whether to create the account-level ClaimedAccountConcurrency alarm."
  type        = bool
  default     = true
}
```

- [ ] **Step 4: Filter the duration alarm (Pattern C).** Replace `for_each = local.lambda_resources` on the `duration` block with the filtered form using `"duration"`.

- [ ] **Step 5: Gate the concurrency alarm.** In the `concurrency` block, change:

```hcl
  count = length(var.resources) > 0 ? 1 : 0
```
to:
```hcl
  count = var.concurrency_alarm_enabled && length(var.resources) > 0 ? 1 : 0
```

- [ ] **Step 6: Validate** — standard per-module test (`type` = `lambda`).

- [ ] **Step 7: Commit.**

```bash
git add modules/cloudwatch/metrics-alarm/lambda/variables.tf modules/cloudwatch/metrics-alarm/lambda/main.tf
git commit -m "feat(metrics): add disabled_alarms (duration) and concurrency_alarm_enabled to lambda module"
```

---

## Task 8: S3 module (error_5xx only; replication untouched)

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/s3/variables.tf`
- Modify: `modules/cloudwatch/metrics-alarm/s3/main.tf`

Local map: `local.s3_resources`. Only `error_5xx` is toggleable via `disabled_alarms`. **Do not** touch `replication_enabled` or the `replication_failed` alarm — replication stays a separate opt-in gate (the metric only exists when replication is configured).

- [ ] **Step 1: Pattern A** — add `disabled_alarms = optional(set(string), [])` to the `overrides` object in `variables.tf` (keep the existing `replication_enabled` field).

- [ ] **Step 2: Pattern B** — add validation block with id list `["error_5xx"]` and error message `"overrides.disabled_alarms entries must be a subset of: error_5xx"`.

- [ ] **Step 3: Pattern C** — filter `for_each` on the `error_5xx` alarm block only, replacing `local.s3_resources` with the filtered form using `"error_5xx"`. Leave the `replication_failed` block's `for_each = local.s3_replication_resources` unchanged.

- [ ] **Step 4: Validate** — standard per-module test (`type` = `s3`).

- [ ] **Step 5: Commit.**

```bash
git add modules/cloudwatch/metrics-alarm/s3/variables.tf modules/cloudwatch/metrics-alarm/s3/main.tf
git commit -m "feat(metrics): add disabled_alarms (error_5xx) to s3 module"
```

---

## Task 9: Single-metric modules (apigateway, asg, ses)

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/apigateway/{variables.tf,main.tf}`
- Modify: `modules/cloudwatch/metrics-alarm/asg/{variables.tf,main.tf}`
- Modify: `modules/cloudwatch/metrics-alarm/ses/{variables.tf,main.tf}`

Per-module values:

| Module | Local map | Resource label = metric_id |
|---|---|---|
| apigateway | `local.apigateway_resources` | `error_5xx` |
| asg | `local.asg_resources` | `in_service_capacity` |
| ses | `local.ses_resources` | `bounce_rate` |

- [ ] **Step 1: apigateway** — Pattern A; Pattern B with id list `["error_5xx"]`; Pattern C on the `error_5xx` block replacing `local.apigateway_resources`.

- [ ] **Step 2: asg** — Pattern A; Pattern B with id list `["in_service_capacity"]`; Pattern C on the `in_service_capacity` block replacing `local.asg_resources`.

- [ ] **Step 3: ses** — Pattern A; Pattern B with id list `["bounce_rate"]`; Pattern C on the `bounce_rate` block replacing `local.ses_resources`.

- [ ] **Step 4: Validate all three** — run the standard per-module test for `apigateway`, `asg`, and `ses`.

- [ ] **Step 5: Commit.**

```bash
git add modules/cloudwatch/metrics-alarm/apigateway modules/cloudwatch/metrics-alarm/asg modules/cloudwatch/metrics-alarm/ses
git commit -m "feat(metrics): add disabled_alarms toggle to apigateway, asg, ses modules"
```

---

## Task 10: Project stack passthrough (billing/dev)

**Files:**
- Modify: `stacks/projects/billing/dev/variables.tf`

The project stack re-declares each resource type so tfvars can be parsed before reaching the module. Add the `disabled_alarms` field to every `<type>_resources` overrides object so tfvars may pass it through. **No validation here** — the library module validates the IDs. For Lambda, the `concurrency_alarm_enabled` is a module input wired in `main.tf` (see Step 2), not a resource override.

- [ ] **Step 1: Add the field to all eleven overrides objects.** In each of `alb_resources`, `apigateway_resources`, `ec2_resources`, `asg_resources`, `lambda_resources`, `rds_resources`, `s3_resources`, `elasticache_resources`, `opensearch_resources`, `ses_resources`, `cloudfront_resources`, add as the last attribute of the `overrides` object:

```hcl
      disabled_alarms = optional(set(string), [])
```

- [ ] **Step 2: (Optional) expose concurrency toggle.** If a project should be able to disable the Lambda account-level alarm, add a stack variable and wire it. In `stacks/projects/billing/dev/variables.tf`:

```hcl
variable "lambda_concurrency_alarm_enabled" {
  description = "Whether to create the account-level Lambda concurrency alarm."
  type        = bool
  default     = true
}
```

Then in `stacks/projects/billing/dev/main.tf`, in the `lambda_alarms` module block, add:

```hcl
  concurrency_alarm_enabled = var.lambda_concurrency_alarm_enabled
```

- [ ] **Step 3: Validate the stack parses** (no backend init / no AWS needed for type-checking the variables):

```bash
cd stacks/projects/billing/dev
terraform fmt -check
```
Expected: no output (already formatted). Full `terraform validate` here requires backend + remote state, so defer plan-level validation to the work machine.

- [ ] **Step 4: Commit.**

```bash
git add stacks/projects/billing/dev/variables.tf stacks/projects/billing/dev/main.tf
git commit -m "feat(metrics): pass disabled_alarms through billing/dev project stack"
```

---

## Task 11: Preflight scripts respect disabled_alarms

**Files:**
- Modify: `scripts/check_ec2_mem_metric.sh` (skip resources where `memory` is disabled)
- Modify: `scripts/check_asg_metrics.sh` (skip where `in_service_capacity` is disabled)
- Modify: `scripts/check_s3_metrics.sh` (skip where `error_5xx` is disabled)
- Create: `scripts/tests/fixture.tfvars` (test fixture)

Each script currently extracts resource names with a flat regex. Replace the name-extraction `python3` heredoc with a brace-aware parser that skips a resource when the relevant metric ID appears in its `disabled_alarms`.

- [ ] **Step 1: Write a fixture tfvars** to test the parser logic without AWS. Create `scripts/tests/fixture.tfvars`:

```hcl
aws_region = "ap-northeast-1"

ec2_resources = [
  { name = "keep-ec2" },
  {
    name      = "skip-ec2"
    overrides = { disabled_alarms = ["memory"] }
  },
]

asg_resources = [
  { name = "keep-asg", desired_capacity = 2 },
  {
    name             = "skip-asg"
    desired_capacity = 2
    overrides        = { disabled_alarms = ["in_service_capacity"] }
  },
]

s3_resources = [
  { name = "keep-bucket" },
  {
    name      = "skip-bucket"
    overrides = { disabled_alarms = ["error_5xx"] }
  },
]
```

- [ ] **Step 2: Update `check_ec2_mem_metric.sh`.** Replace the `NAMES=$(python3 - "$TFVARS" <<'EOF' ... EOF )` block with the brace-aware parser (metric `memory`, list `ec2_resources`):

```bash
NAMES=$(python3 - "$TFVARS" "ec2_resources" "memory" <<'EOF'
import re, sys
content = open(sys.argv[1]).read()
list_var, metric = sys.argv[2], sys.argv[3]

start = re.search(rf'{list_var}\s*=\s*\[', content)
if not start:
    sys.exit(0)

# Capture the bracketed list body by depth.
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
```

- [ ] **Step 3: Update `check_asg_metrics.sh`** — same replacement, with args `"asg_resources" "in_service_capacity"`.

- [ ] **Step 4: Update `check_s3_metrics.sh`** — same replacement, with args `"s3_resources" "error_5xx"`.

- [ ] **Step 5: Test the parser against the fixture** (no AWS). Run each extractor in isolation and confirm the `skip-*` resource is omitted:

```bash
for spec in "ec2_resources memory keep-ec2 skip-ec2" "asg_resources in_service_capacity keep-asg skip-asg" "s3_resources error_5xx keep-bucket skip-bucket"; do
  set -- $spec
  LIST=$1 METRIC=$2 KEEP=$3 SKIP=$4
  OUT=$(python3 - scripts/tests/fixture.tfvars "$LIST" "$METRIC" <<'EOF'
import re, sys
content = open(sys.argv[1]).read()
list_var, metric = sys.argv[2], sys.argv[3]
start = re.search(rf'{list_var}\s*=\s*\[', content)
if not start: sys.exit(0)
i, depth, body = start.end(), 1, []
while i < len(content) and depth > 0:
    c = content[i]
    if c == '[': depth += 1
    elif c == ']':
        depth -= 1
        if depth == 0: break
    body.append(c); i += 1
body = ''.join(body)
entries, depth, cur = [], 0, []
for c in body:
    if c == '{':
        depth += 1
        if depth == 1: cur = []; continue
    if c == '}':
        depth -= 1
        if depth == 0: entries.append(''.join(cur)); continue
    if depth >= 1: cur.append(c)
for e in entries:
    nm = re.search(r'name\s*=\s*"([^"]+)"', e)
    if not nm: continue
    da = re.search(r'disabled_alarms\s*=\s*\[([^\]]*)\]', e)
    disabled = re.findall(r'"([^"]+)"', da.group(1)) if da else []
    if metric in disabled: continue
    print(nm.group(1))
EOF
)
  echo "$OUT" | grep -qx "$KEEP" && ! echo "$OUT" | grep -qx "$SKIP" \
    && echo "PASS: $LIST keeps $KEEP, skips $SKIP" \
    || { echo "FAIL: $LIST -> [$OUT]"; exit 1; }
done
```
Expected: three `PASS:` lines.

- [ ] **Step 6: Commit.**

```bash
git add scripts/check_ec2_mem_metric.sh scripts/check_asg_metrics.sh scripts/check_s3_metrics.sh scripts/tests/fixture.tfvars
git commit -m "feat(metrics): preflight scripts skip resources with the metric in disabled_alarms"
```

---

## Task 12: Documentation

**Files:**
- Modify: `CLAUDE.md` (Module Pattern section)
- Modify: `stacks/projects/billing/dev/terraform.tfvars.example`

- [ ] **Step 1: Document in `CLAUDE.md`.** In the "Module Pattern" section, after the threshold-resolution sentence, add:

```markdown
- `overrides.disabled_alarms`: an optional `set(string)` of metric IDs to skip for a
  resource (opt-out; default = all metrics on). Each module's `resources` variable validates
  the IDs against that module's metric set. Disabled metrics' `aws_cloudwatch_metric_alarm`
  resources are filtered out of `for_each`, so no alarm is created. Two exceptions: S3
  replication is gated by `overrides.replication_enabled` (opt-in, not `disabled_alarms`), and
  the Lambda account-level concurrency alarm is gated by the module input
  `concurrency_alarm_enabled`.
```

- [ ] **Step 2: Add an example to `terraform.tfvars.example`.** Replace the commented `alb_resources` example block with one that shows `disabled_alarms`:

```hcl
alb_resources = [
  # {
  #   name = "billing-alb"
  #   overrides = {
  #     # Skip specific metric alarms for this resource (opt-out; default = all on).
  #     # Valid ALB IDs: elb_5xx, target_5xx, unhealthy_host, target_response_time
  #     disabled_alarms = ["target_response_time"]
  #   }
  # }
]
```

- [ ] **Step 3: Commit.**

```bash
git add CLAUDE.md stacks/projects/billing/dev/terraform.tfvars.example
git commit -m "docs: document disabled_alarms per-metric toggle"
```

---

## Final Verification

- [ ] **Run all module validations** (where `terraform` exists). For each `type` in alb, apigateway, asg, cloudfront, ec2, elasticache, lambda, opensearch, rds, s3, ses:

```bash
cd modules/cloudwatch/metrics-alarm/<type> && terraform init -backend=false && terraform validate && cd -
```
Expected: `Success!` for all eleven.

- [ ] **Run the CloudFront behavioral test:** `cd modules/cloudwatch/metrics-alarm/cloudfront && terraform test` → `3 passed`.

- [ ] **Run the preflight parser test** (Task 11, Step 5) → three `PASS:` lines.

- [ ] **Format check:** from repo root, `terraform fmt -recursive` reports no changes.

- [ ] **Work-machine-only (deferred, needs AWS + remote state):** in `stacks/projects/billing/dev`, set `disabled_alarms = ["memory"]` on a real EC2 resource and confirm `terraform plan` drops the `...-mem_used_percent` alarm and shows no other diffs.

## Notes / Out of Scope

- The existing per-resource `enabled` (mute notifications) flag is unchanged.
- No type-level / project-wide default toggle — per-resource only.
- RDS `volume_bytes_used` stays commented out and is excluded from valid IDs.
- Only one project stack exists today (`billing/dev`). Future project stacks must add the
  `disabled_alarms` field to their re-declared types (same as Task 10).
