# EFS/JMX Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all 10 findings from the 2026-07-14 code review of the `feat/efs-and-jmx-monitoring` branch (EFS + JMX monitoring), without changing the alarm semantics that already verified as correct.

**Architecture:** All changes land on the existing `feat/efs-and-jmx-monitoring` branch. They are small, independent hardening fixes: one agent-config pin, stack output/wiring additions, new `validation {}` blocks, a single-lookup refactor in the JMX module, output-key renames, one new preflight script, and doc corrections. No alarm thresholds, metric expressions, or alarm names change; nothing here is deployed from this machine (two-machine workflow — applies happen on the work machine).

**Tech Stack:** Terraform ≥ 1.10 (containerized via podman — terraform is NOT on the host), hashicorp/aws ≥ 5.0, bash + awscli (preflight script), GitHub Actions.

## Review Findings Being Fixed (severity order)

| # | Finding | Task |
|---|---------|------|
| F1 | cwagent JMX config doesn't pin `metrics_collection_interval: 60`; merged configs inherit shorter global intervals → `gc_time` false alarms at up to 6× sensitivity (CONFIRMED vs AWS docs) | Task 1 |
| F2 | `stacks/projects/billing/dev/outputs.tf` never got `efs`/`jmx` entries → alarms invisible to remote-state consumers | Task 2 |
| F3 | EFS: two resources with the same friendly `name` render identical `alarm_name` → both Terraform resources upsert one CloudWatch alarm, one fs silently unmonitored | Task 3 |
| F4 | EFS: `overrides.period`/`overrides.evaluation_periods` are the only unvalidated overrides in the repo → CloudWatch-invalid combos fail at apply, not plan | Task 3 |
| F5 | No JMX preflight check; `notBreaching` alarms sit green forever if the agent config was never deployed on the host | Task 8 |
| F6 | JMX: `data.aws_instance.this` duplicates `data.aws_instances.by_name` (2N API calls/plan) and hard-errors on 0/multi Name-tag matches before the friendly `check {}` can surface | Task 5 |
| F7 | `dashboards/jmx-jvm.json` is a hand-copy of the dashboard module's layout; module wired into no stack; README regen command references an output no stack exposes | Task 7 |
| F8 | Dashboard module takes raw unvalidated `instance_id`s; JMX alarm module resolves IDs but doesn't export them → hardcoded stale IDs in the intended pairing | Tasks 6, 7 |
| F9 | Doc claims contradicted by code: "repo's only metric-math alarm"; "agent appends ImageId/InstanceType" (config appends only InstanceId) | Task 9 |
| F10 | EFS/JMX outputs keyed by internal metric id (`throughput_util`, `heap_used`, `gc_time`) instead of the documented `<resource-key>:<metric-name>` contract | Task 4 |

**Explicitly out of scope** (reviewed, deliberately not done here):
- The EC2 module shares the double-lookup pattern from F6. It is deployed; changing it belongs in its own PR with a plan-churn check on the work machine. This plan fixes only the (undeployed) JMX module.
- `drop_original_metrics` in the cwagent config (cost trim, ~$3/instance/mo): agent support for `jvm.*` names was not verified; do not add it blind.
- GC `DIFF(Sum)` sample-jitter: verified as a dashboard-artifact risk only (3-of-3 + notBreaching protect the alarm); accepted.

## Global Constraints

- **Branch:** all work on `feat/efs-and-jmx-monitoring`. Do not merge to main; do not push unless the human asks.
- **Terraform is containerized.** Host has no terraform. Every terraform command runs as:
  ```bash
  podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 sh -c "<command>"
  ```
  Run from the directory you want as `$PWD`. `:Z` is required (Fedora SELinux). `python3` IS on the host.
- **No AWS credentials on this machine.** All verification is offline: `terraform validate`, `terraform fmt -check`, and offline `terraform plan` against a local fixture using the fake-creds provider block shown in Task 3. Never attempt a real plan/apply of the stacks (`stacks/projects/billing/dev` full validate needs remote state — exercised on the work machine only).
- **Do not change:** alarm names, metric expressions, thresholds, `treat_missing_data`, severities, or the `disabled_alarms` ids (`throughput_util`, `heap_used`, `gc_time` remain the opt-out ids — only OUTPUT MAP KEYS change in Task 4).
- Repo convention: conventional commits (`fix(jmx): …`, `feat(metrics): …`, `docs: …`).
- Module validation command (used by several tasks; run inside the module dir):
  ```bash
  podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
    sh -c "terraform init -backend=false -input=false >/dev/null && terraform validate"
  ```
  Expected on success: `Success! The configuration is valid.`

---

### Task 0: Setup

**Files:**
- Commit (already created): `docs/superpowers/plans/2026-07-15-efs-jmx-review-fixes.md`

- [ ] **Step 1: Check out the feature branch**

```bash
cd /home/eric/Documents/Code/terraform/resource-type-based-metric-alarm
git checkout feat/efs-and-jmx-monitoring
git status --short
```
Expected: branch switches; `git status` shows only the untracked plan file `docs/superpowers/plans/2026-07-15-efs-jmx-review-fixes.md`.

- [ ] **Step 2: Commit the plan**

```bash
git add docs/superpowers/plans/2026-07-15-efs-jmx-review-fixes.md
git commit -m "docs: implementation plan for EFS/JMX review fixes"
```

---

### Task 1: Pin the JMX collection interval (F1)

**Files:**
- Modify: `cwagent/jmx/amazon-cloudwatch-agent-jmx.json`
- Modify: `cwagent/jmx/README.md`
- Modify: `CLAUDE.md` (JMX bullet, one clause)

**Interfaces:**
- Consumes: nothing.
- Produces: the agent-config contract now includes `metrics_collection_interval: 60` inside the `jmx` block. Later tasks don't depend on it, but the `gc_time` alarm's `stat=Sum`/`DIFF` math does.

Why: the CloudWatch agent applies the agent-section `metrics_collection_interval` to every `metrics_collected` section that doesn't set its own. The README's deploy option A tells operators to merge this snippet into an existing config; a host config with a global 10s/30s interval would then put 6/2 cumulative samples per 60s period, `stat=Sum` multiplies the counter, and `DIFF` inflates GC time 6×/2× → sustained false alarms. A section-level interval overrides the global one, closing the hole.

- [ ] **Step 1: Add the interval to the jmx block**

Edit `cwagent/jmx/amazon-cloudwatch-agent-jmx.json` — the `jmx` array entry currently starts:
```json
      "jmx": [
        {
          "endpoint": "localhost:9999",
```
Change to:
```json
      "jmx": [
        {
          "endpoint": "localhost:9999",
          "metrics_collection_interval": 60,
```
(One added line; everything else unchanged.)

- [ ] **Step 2: Verify valid JSON**

```bash
python3 -m json.tool cwagent/jmx/amazon-cloudwatch-agent-jmx.json > /dev/null && echo "valid json"
```
Expected: `valid json`

- [ ] **Step 3: Update the README contract + GC note**

In `cwagent/jmx/README.md`:

(a) In the `## Contract` list, add one bullet after the **Metrics:** bullet:
```markdown
- **Collection interval:** `metrics_collection_interval: 60` is pinned inside the `jmx`
  block — it must equal the alarm/widget period (60s). Keep the pin when merging this
  snippet into an existing agent config; a shorter inherited interval breaks the
  `gc_time` alarm's `stat = Sum` math (over-counts the cumulative GC counter).
```

(b) In the "**GC and the per-collector rollup.**" paragraph, replace the final sentence:
```markdown
This is correct as long as JMX is collected at 60s (= the alarm/widget
period) so there is one datapoint per period — a summed cumulative counter would over-count
if the JMX `metrics_collection_interval` were set below the period.
```
with:
```markdown
This is correct as long as JMX is collected at 60s (= the alarm/widget
period) so there is one datapoint per period — a summed cumulative counter would over-count
if the JMX collection interval were below the period. The shipped config pins
`metrics_collection_interval: 60` inside the `jmx` block for exactly this reason; do not
remove the pin when merging into an existing agent config.
```

- [ ] **Step 4: Update the CLAUDE.md JMX bullet's closing clause**

In `CLAUDE.md`, the JMX bullet ends:
```
`Sum` is correct while JMX collects at 60s (= the alarm period).
```
Replace with:
```
`Sum` is correct while JMX collects at 60s (= the alarm period; pinned via `metrics_collection_interval: 60` in the config).
```

- [ ] **Step 5: Commit**

```bash
git add cwagent/jmx/amazon-cloudwatch-agent-jmx.json cwagent/jmx/README.md CLAUDE.md
git commit -m "fix(jmx): pin metrics_collection_interval to 60s in agent config"
```

---

### Task 2: Export EFS/JMX alarms from the stack outputs (F2)

**Files:**
- Modify: `stacks/projects/billing/dev/outputs.tf`
- Modify: `CLAUDE.md` ("Adding a New Resource Type" — add step 5, so this omission can't recur)

**Interfaces:**
- Consumes: `module.efs_alarms` / `module.jmx_alarms` (already in the stack's `main.tf`, both `count`-gated).
- Produces: `alarm_arns.efs`, `alarm_arns.jmx` (and same under `alarm_names`) in the stack outputs.

- [ ] **Step 1: Add efs/jmx entries to both output maps**

In `stacks/projects/billing/dev/outputs.tf`, both `output "alarm_arns"` and `output "alarm_names"` value maps currently end with:
```hcl
    cloudfront  = try(module.cloudfront_alarms[0].alarm_arns, {})
```
(and `alarm_names` respectively). Add after the `cloudfront` line in **each** of the two outputs:
```hcl
    efs         = try(module.efs_alarms[0].alarm_arns, {})
    jmx         = try(module.jmx_alarms[0].alarm_arns, {})
```
in `alarm_arns`, and
```hcl
    efs         = try(module.efs_alarms[0].alarm_names, {})
    jmx         = try(module.jmx_alarms[0].alarm_names, {})
```
in `alarm_names`.

- [ ] **Step 2: Verify formatting and module resolution**

```bash
cd stacks/projects/billing/dev
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
  sh -c "terraform fmt -check && terraform init -backend=false -input=false 2>&1 | tail -3"
cd -
```
Expected: `fmt -check` prints nothing (exit 0); init output ends with `Terraform has been successfully initialized!` (full `validate` is a work-machine job — remote state).

- [ ] **Step 3: Add step 5 to CLAUDE.md's "Adding a New Resource Type"**

Current section ends with step 4:
```markdown
4. Add a `module "<type>_alarms"` block to the stack's `main.tf` with `count = length(var.<type>_resources) > 0 ? 1 : 0`.
```
Append:
```markdown
5. Add `<type> = try(module.<type>_alarms[0].alarm_arns, {})` (and the `alarm_names` twin) to the stack's `outputs.tf` — remote-state consumers only see alarms that are exported here.
```

- [ ] **Step 4: Commit**

```bash
git add stacks/projects/billing/dev/outputs.tf CLAUDE.md
git commit -m "fix(metrics): export EFS/JMX alarm maps from billing/dev stack outputs"
```

---

### Task 3: EFS validation hardening (F3 + F4)

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/efs/variables.tf`
- Temp (never committed): `.fixture-validate/main.tf` at repo root

The test cycle uses an **offline plan fixture**: the EFS module has no data sources, so with a fake-credentials provider block `terraform plan` runs fully offline and exercises `validation {}` blocks against real values (which `terraform validate` alone cannot).

- [ ] **Step 1: Create the failing fixture (bad values that SHOULD be rejected)**

```bash
mkdir -p .fixture-validate
cat > .fixture-validate/main.tf <<'EOF'
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

module "efs" {
  source  = "../modules/cloudwatch/metrics-alarm/efs"
  project = "test"
  env     = "dev"

  # BAD on purpose:
  #  - duplicate friendly name across two fs      (F3)
  #  - period not a multiple of 60                (F4)
  #  - period * evaluation_periods > 86400        (F4)
  resources = [
    { file_system_id = "fs-0000000000000000a", name = "dup-name" },
    { file_system_id = "fs-0000000000000000b", name = "dup-name" },
    {
      file_system_id = "fs-0000000000000000c"
      overrides      = { period = 90 } # not a multiple of 60
    },
    {
      file_system_id = "fs-0000000000000000d"
      overrides      = { evaluation_periods = 48 } # 3600 * 48 = 172800 > 86400
    },
  ]

  sns_topic_arns = {
    WARN  = "arn:aws:sns:us-east-1:111111111111:warn"
    ERROR = "arn:aws:sns:us-east-1:111111111111:error"
    CRIT  = "arn:aws:sns:us-east-1:111111111111:crit"
  }
}
EOF
```

- [ ] **Step 2: Run the fixture plan — verify it currently SUCCEEDS (the bug)**

```bash
cd .fixture-validate
podman run --rm -v "$PWD/..":/work:Z -w /work/.fixture-validate docker.io/hashicorp/terraform:1.10 \
  sh -c "terraform init -input=false >/dev/null && terraform plan -input=false 2>&1 | tail -5"
cd -
```
Expected (this is the failing state we're fixing): plan completes, ending with something like `Plan: 4 to add, 0 to change, 0 to destroy.` — none of the bad values are rejected.

- [ ] **Step 3: Add the three validation blocks**

In `modules/cloudwatch/metrics-alarm/efs/variables.tf`, inside `variable "resources"`, after the existing `disabled_alarms` validation block (the one whose error message is `"overrides.disabled_alarms entries must be a subset of: throughput_util"`), add:

```hcl
  validation {
    condition     = length(distinct([for r in var.resources : coalesce(r.name, r.file_system_id)])) == length(var.resources)
    error_message = "coalesce(name, file_system_id) must be unique across resources — duplicate friendly names make two entries render the same alarm_name, and CloudWatch upserts by name (one file system would be silently unmonitored)."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.period, null) == null
      || (coalesce(try(r.overrides.period, null), 3600) >= 60 && coalesce(try(r.overrides.period, null), 3600) % 60 == 0)
    ])
    error_message = "overrides.period must be a multiple of 60 seconds (>= 60), or omitted."
  }
  validation {
    condition = alltrue([
      for r in var.resources :
      coalesce(try(r.overrides.evaluation_periods, null), 6) >= 1
      && coalesce(try(r.overrides.period, null), 3600) * coalesce(try(r.overrides.evaluation_periods, null), 6) <= 86400
    ])
    error_message = "overrides.evaluation_periods must be >= 1, and period * evaluation_periods must not exceed 86400 seconds (CloudWatch's one-day evaluation-interval limit)."
  }
```

- [ ] **Step 4: Re-run the fixture plan — verify all three rejections fire**

Same command as Step 2 but show more output:
```bash
cd .fixture-validate
podman run --rm -v "$PWD/..":/work:Z -w /work/.fixture-validate docker.io/hashicorp/terraform:1.10 \
  sh -c "terraform plan -input=false 2>&1 | grep -E 'Error|error_message|must' | head -12"
cd -
```
Expected: plan FAILS with three `Invalid value for variable` errors whose messages include "must be unique across resources", "must be a multiple of 60 seconds", and "must not exceed 86400 seconds".

- [ ] **Step 5: Verify good values still pass**

Replace the fixture's `resources` list with valid entries and re-plan:
```bash
python3 - <<'EOF'
import re
p = ".fixture-validate/main.tf"
s = open(p).read()
good = '''resources = [
    { file_system_id = "fs-0000000000000000a", name = "efs-a" },
    {
      file_system_id = "fs-0000000000000000b"
      overrides      = { period = 3600, evaluation_periods = 24 } # 86400 exactly: allowed
    },
  ]'''
s = re.sub(r"resources = \[.*?\n  \]", good, s, flags=re.S)
open(p, "w").write(s)
EOF
cd .fixture-validate
podman run --rm -v "$PWD/..":/work:Z -w /work/.fixture-validate docker.io/hashicorp/terraform:1.10 \
  sh -c "terraform plan -input=false 2>&1 | tail -3"
cd -
```
Expected: `Plan: 2 to add, 0 to change, 0 to destroy.`

- [ ] **Step 6: Remove the fixture, validate the module, commit**

```bash
rm -rf .fixture-validate
cd modules/cloudwatch/metrics-alarm/efs
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
  sh -c "terraform init -backend=false -input=false >/dev/null && terraform validate"
cd -
git add modules/cloudwatch/metrics-alarm/efs/variables.tf
git commit -m "feat(efs): validate period/evaluation_periods and alarm-name uniqueness"
```
Expected before commit: `Success! The configuration is valid.` Confirm `git status` shows no `.fixture-validate` leftovers.

---

### Task 4: Key outputs by metric name, not internal id (F10)

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/efs/outputs.tf`
- Modify: `modules/cloudwatch/metrics-alarm/jmx/outputs.tf`

**Interfaces:**
- Produces: output keys `"<fs-id>:ThroughputUtilization"`, `"<name>:HeapUsedPercent"`, `"<name>:GcTimeMsPerMinute"` — matching each alarm's name suffix, per CLAUDE.md's Module Pattern (`"<resource-key>:<metric-name>"`, as ec2 does with `CPUUtilization`).
- **Not changed:** `disabled_alarms` ids stay `throughput_util` / `heap_used` / `gc_time` (they are resource labels, a separate contract).

- [ ] **Step 1: Rewrite `modules/cloudwatch/metrics-alarm/efs/outputs.tf`**

Replace the whole file with:
```hcl
output "alarm_arns" {
  description = "Map of <resource-key>:<metric-name> to alarm ARN for every alarm this module creates."
  value       = { for k, v in aws_cloudwatch_metric_alarm.throughput_util : "${k}:ThroughputUtilization" => v.arn }
}

output "alarm_names" {
  description = "Map of <resource-key>:<metric-name> to alarm name for every alarm this module creates."
  value       = { for k, v in aws_cloudwatch_metric_alarm.throughput_util : "${k}:ThroughputUtilization" => v.alarm_name }
}
```

- [ ] **Step 2: Rewrite `modules/cloudwatch/metrics-alarm/jmx/outputs.tf`**

Replace the whole file with:
```hcl
output "alarm_arns" {
  description = "Map of <resource-key>:<metric-name> to alarm ARN for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.heap_used : "${k}:HeapUsedPercent" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.gc_time : "${k}:GcTimeMsPerMinute" => v.arn }
  )
}

output "alarm_names" {
  description = "Map of <resource-key>:<metric-name> to alarm name for every alarm this module creates."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.heap_used : "${k}:HeapUsedPercent" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.gc_time : "${k}:GcTimeMsPerMinute" => v.alarm_name }
  )
}
```
(Task 6 adds a third output to this file; keep these two as shown.)

- [ ] **Step 3: Validate both modules**

```bash
for m in efs jmx; do
  cd modules/cloudwatch/metrics-alarm/$m
  podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
    sh -c "terraform init -backend=false -input=false >/dev/null && terraform validate"
  cd -
done
```
Expected: `Success! The configuration is valid.` twice.

- [ ] **Step 4: Commit**

```bash
git add modules/cloudwatch/metrics-alarm/efs/outputs.tf modules/cloudwatch/metrics-alarm/jmx/outputs.tf
git commit -m "fix(metrics): key EFS/JMX outputs by metric name per module contract"
```

---

### Task 5: Single instance lookup + per-alarm preconditions in JMX (F6)

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/jmx/main.tf`
- Modify: `CLAUDE.md` (JMX bullet lookup clause)

**Interfaces:**
- Produces: `local.instance_ids` — `map(string)` of resource name ⇒ resolved InstanceId (`"unresolved"` when the Name tag matched ≠ 1 instances; preconditions fail the plan before that value reaches AWS). Task 6 exports this as the `instance_ids` output.
- Removes: `data.aws_instance.this` (the singular data source). The `check {}` block and `data.aws_instances.by_name` remain.

Why: `data.aws_instance` hard-errors with a raw provider message on 0/multiple matches, so the friendly `check {}` never gets its turn, and it duplicates the `data.aws_instances` call (2N DescribeInstances per plan). Switching the alarms to `data.aws_instances.by_name[...].ids[0]` behind a `precondition` halves the API calls and makes every failure mode print the friendly message. `try(..., "unresolved")` prevents an index-out-of-range crash on the 0-match path so the precondition is what the operator sees.

- [ ] **Step 1: Add `instance_ids` to locals**

In `modules/cloudwatch/metrics-alarm/jmx/main.tf`, the `locals` block currently reads:
```hcl
locals {
  name_prefix   = "${var.project}-${var.env}-JMX"
  jmx_resources = { for res in var.resources : res.name => res }

  default_severities = {
    heap_used = "WARN"
    gc_time   = "WARN"
  }
}
```
Add one entry:
```hcl
locals {
  name_prefix   = "${var.project}-${var.env}-JMX"
  jmx_resources = { for res in var.resources : res.name => res }

  # Resolved by the single data.aws_instances lookup below. "unresolved" only
  # exists so the expression can't index-crash on a zero-match; the per-alarm
  # preconditions fail the plan (with the resource name) before it is ever used.
  instance_ids = { for k, d in data.aws_instances.by_name : k => try(d.ids[0], "unresolved") }

  default_severities = {
    heap_used = "WARN"
    gc_time   = "WARN"
  }
}
```

- [ ] **Step 2: Delete the singular data source**

Delete this entire block (after the `check "jmx_name_tag_uniqueness"` block):
```hcl
data "aws_instance" "this" {
  for_each = local.jmx_resources

  filter {
    name   = "tag:Name"
    values = [each.value.name]
  }

  filter {
    name   = "instance-state-name"
    values = ["running", "stopped"]
  }
}
```
Keep `data "aws_instances" "by_name"` and the `check` block unchanged.

- [ ] **Step 3: Repoint both alarms and add preconditions**

In **both** `resource "aws_cloudwatch_metric_alarm" "heap_used"` and `resource "aws_cloudwatch_metric_alarm" "gc_time"`:

(a) Replace every dimensions line
```hcl
      dimensions  = { InstanceId = data.aws_instance.this[each.key].id }
```
with
```hcl
      dimensions  = { InstanceId = local.instance_ids[each.key] }
```
(two occurrences in `heap_used` — m1 and m2 — and one in `gc_time`).

(b) Add at the end of each resource body (after `tags = merge(...)`):
```hcl
  lifecycle {
    precondition {
      condition     = length(data.aws_instances.by_name[each.key].ids) == 1
      error_message = "JMX resource '${each.key}' must match exactly one running/stopped EC2 instance by Name tag (matched ${length(data.aws_instances.by_name[each.key].ids)})."
    }
  }
```

- [ ] **Step 4: Validate the module**

```bash
cd modules/cloudwatch/metrics-alarm/jmx
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
  sh -c "terraform init -backend=false -input=false >/dev/null && terraform validate"
cd -
grep -c "data.aws_instance\." modules/cloudwatch/metrics-alarm/jmx/main.tf || true
```
Expected: `Success! The configuration is valid.` and the grep count is `0` (no `data.aws_instance.` references remain; `data.aws_instances.` with the plural `s` is fine and expected).

- [ ] **Step 5: Update the CLAUDE.md JMX bullet**

The bullet currently says:
```
- **JMX**: Heap/GC alarms for Java apps on EC2, by Name tag (same InstanceId lookup + `check {}` as EC2).
```
Replace that opening with:
```
- **JMX**: Heap/GC alarms for Java apps on EC2, by Name tag (single `data.aws_instances` lookup; a `check {}` warns on ambiguous Name tags and per-alarm `precondition`s fail the plan with the resource name on a 0/multi match — unlike EC2, which still uses `data.aws_instance`).
```
(Rest of the bullet unchanged.)

- [ ] **Step 6: Commit**

```bash
git add modules/cloudwatch/metrics-alarm/jmx/main.tf CLAUDE.md
git commit -m "refactor(jmx): single instance lookup with per-alarm preconditions"
```

---

### Task 6: Export resolved instance IDs; validate dashboard input (F8)

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/jmx/outputs.tf`
- Modify: `modules/cloudwatch/dashboard/jmx/variables.tf`

**Interfaces:**
- Consumes: `local.instance_ids` from Task 5.
- Produces: JMX module output `instance_ids` — `map(string)`, resource name ⇒ InstanceId. Task 7 feeds it to the dashboard module.
- Produces: dashboard module rejects non-`i-…` instance ids at plan time.

- [ ] **Step 1: Add the `instance_ids` output**

Append to `modules/cloudwatch/metrics-alarm/jmx/outputs.tf`:
```hcl
output "instance_ids" {
  description = "Map of resource name => resolved EC2 InstanceId, for pairing with modules/cloudwatch/dashboard/jmx (instances = [for n, id in ...instance_ids : { name = n, instance_id = id }])."
  value       = local.instance_ids
}
```

- [ ] **Step 2: Add validation to the dashboard module's `instances`**

In `modules/cloudwatch/dashboard/jmx/variables.tf`, `variable "instances"` currently has no validation. Add inside it, after the `type` attribute:
```hcl
  validation {
    condition     = alltrue([for i in var.instances : can(regex("^i-[0-9a-f]{8,17}$", i.instance_id))])
    error_message = "instances[*].instance_id must be an EC2 instance id (i-xxxxxxxxxxxxxxxxx). Pass resolved IDs — e.g. module.jmx_alarms[0].instance_ids — not Name tags."
  }
```
(This also catches the `"unresolved"` sentinel from Task 5, as a second line of defense behind the preconditions.)

- [ ] **Step 3: Validate both modules**

```bash
for m in metrics-alarm/jmx dashboard/jmx; do
  cd modules/cloudwatch/$m
  podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
    sh -c "terraform init -backend=false -input=false >/dev/null && terraform validate"
  cd -
done
```
Expected: `Success! The configuration is valid.` twice.

- [ ] **Step 4: Commit**

```bash
git add modules/cloudwatch/metrics-alarm/jmx/outputs.tf modules/cloudwatch/dashboard/jmx/variables.tf
git commit -m "feat(jmx): export resolved instance_ids; validate dashboard instance ids"
```

---

### Task 7: Wire the dashboard into the stack; fix the regen path (F7 + F8)

**Files:**
- Modify: `stacks/projects/billing/dev/variables.tf`
- Modify: `stacks/projects/billing/dev/main.tf`
- Modify: `stacks/projects/billing/dev/outputs.tf`
- Modify: `dashboards/README.md`

**Interfaces:**
- Consumes: `module.jmx_alarms[0].instance_ids` (Task 6), `var.aws_region` (exists), `var.project`/`var.env`/`var.jmx_resources` (exist).
- Produces: stack variable `jmx_dashboard_enabled` (bool, default `false`), `module "jmx_dashboard"`, stack output `jmx_dashboard_json` — making `dashboards/README.md`'s regeneration command real.

- [ ] **Step 1: Add the enable variable**

Append to `stacks/projects/billing/dev/variables.tf`:
```hcl
variable "jmx_dashboard_enabled" {
  description = "Create the per-instance JVM dashboard for the hosts in jmx_resources (requires jmx_resources to be non-empty)."
  type        = bool
  default     = false
}
```

- [ ] **Step 2: Add the module block**

Append to `stacks/projects/billing/dev/main.tf`:
```hcl
module "jmx_dashboard" {
  source = "../../../../modules/cloudwatch/dashboard/jmx"
  count  = var.jmx_dashboard_enabled && length(var.jmx_resources) > 0 ? 1 : 0

  project   = var.project
  env       = var.env
  region    = var.aws_region
  instances = [for n, id in module.jmx_alarms[0].instance_ids : { name = n, instance_id = id }]
}
```
(The `count` guard guarantees `module.jmx_alarms[0]` exists: `jmx_alarms` uses `count = length(var.jmx_resources) > 0 ? 1 : 0`.)

- [ ] **Step 3: Add the dashboard-body output**

Append to `stacks/projects/billing/dev/outputs.tf`:
```hcl
output "jmx_dashboard_json" {
  description = "Rendered JVM dashboard body (regenerate dashboards/jmx-jvm.json from this after layout changes)."
  value       = try(module.jmx_dashboard[0].dashboard_json, null)
}
```

- [ ] **Step 4: Verify formatting and module resolution**

```bash
cd stacks/projects/billing/dev
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
  sh -c "terraform fmt -check && terraform init -backend=false -input=false 2>&1 | tail -3"
cd -
```
Expected: `fmt -check` silent; init ends `Terraform has been successfully initialized!`.

- [ ] **Step 5: Fix `dashboards/README.md`**

(a) In the "### Terraform (multi-instance, single source of truth)" section, replace the module example (which hardcodes `instance_id = "i-aaaa"`):
```markdown
    module "jvm_dashboard" {
      source = "../../../../modules/cloudwatch/dashboard/jmx"
      project   = var.project
      env       = var.env
      region    = var.aws_region
      instances = [
        { name = "billing-java-app-1", instance_id = "i-aaaa" },
        { name = "billing-java-app-2", instance_id = "i-bbbb" },
      ]
    }
```
with:
```markdown
The billing/dev stack already wires this: set `jmx_dashboard_enabled = true` (with a
non-empty `jmx_resources`) and the dashboard is built for the same hosts the JMX alarms
watch, using the alarm module's resolved `instance_ids` output — no hardcoded IDs:

    module "jmx_dashboard" {
      source = "../../../../modules/cloudwatch/dashboard/jmx"
      count  = var.jmx_dashboard_enabled && length(var.jmx_resources) > 0 ? 1 : 0

      project   = var.project
      env       = var.env
      region    = var.aws_region
      instances = [for n, id in module.jmx_alarms[0].instance_ids : { name = n, instance_id = id }]
    }
```

(b) Replace the final regen paragraph:
```markdown
To regenerate this static file from the module after a layout change:

    terraform -chdir=<stack> output -raw <module>_dashboard_json > dashboards/jmx-jvm.json
```
with:
```markdown
`dashboards/jmx-jvm.json` is a **generated snapshot** — treat the module as the single
source of truth and regenerate the file (work machine, after apply) whenever the module
layout changes:

    terraform -chdir=stacks/projects/billing/dev output -raw jmx_dashboard_json > dashboards/jmx-jvm.json

(then re-insert the `i-PLACEHOLDER` instance id and check the diff only changes what you
intended).
```

- [ ] **Step 6: Commit**

```bash
git add stacks/projects/billing/dev dashboards/README.md
git commit -m "feat(metrics): wire JVM dashboard into billing/dev behind jmx_dashboard_enabled"
```

---

### Task 8: JMX preflight check (F5)

**Files:**
- Create: `scripts/check_jmx_metrics.sh` (mode 0755)
- Modify: `.github/workflows/preflight.yml`
- Modify: `CLAUDE.md` (Preflight Checks section)

**Interfaces:**
- Consumes: tfvars format `jmx_resources = [ { name = "...", overrides = { disabled_alarms = [...] } } ]`; the tfvars-parsing python heredoc is copied verbatim from `scripts/check_ec2_mem_metric.sh` (it is parameterized by list-var and metric id).
- Produces: `scripts/check_jmx_metrics.sh --tfvars <path>`, exit 1 if any required `jvm.*` metric is missing; a new workflow step running it.

Why: both JMX alarms are `treat_missing_data = "notBreaching"` — if the cwagent JMX config was never deployed on a host, the alarms sit green forever. The preflight system exists for exactly this class of prerequisite (CWAgent `mem_used_percent`); extend it.

- [ ] **Step 1: Write the script**

Create `scripts/check_jmx_metrics.sh`:
```bash
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
    nm = re.search(r'name\s*=\s*"([^"]+)"', e)
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
```

```bash
chmod 0755 scripts/check_jmx_metrics.sh
```

- [ ] **Step 2: Smoke-test the tfvars parser offline (no AWS needed)**

The parser must pick up names and honor `disabled_alarms`; test against a temp tfvars:
```bash
cat > /tmp/jmx-test.tfvars <<'EOF'
aws_region = "ap-northeast-1"
jmx_resources = [
  { name = "host-a" },
  {
    name      = "host-b"
    overrides = { disabled_alarms = ["gc_time"] }
  },
]
EOF
bash -c 'source /dev/stdin <<< "$(sed -n "/^extract_names()/,/^}/p" scripts/check_jmx_metrics.sh)"; TFVARS=/tmp/jmx-test.tfvars; echo "HEAP:"; extract_names heap_used; echo "GC:"; extract_names gc_time'
rm /tmp/jmx-test.tfvars
```
Expected output:
```
HEAP:
host-a
host-b
GC:
host-a
```
(`host-b` is excluded from GC because its `gc_time` alarm is disabled.)

Also confirm bash syntax: `bash -n scripts/check_jmx_metrics.sh` → no output.

- [ ] **Step 3: Add the workflow step**

In `.github/workflows/preflight.yml`, after the final step (`Run S3 request metrics check`), append with matching indentation:
```yaml
      - name: Run JMX metric check
        if: steps.changed.outputs.tfvars == 'true'
        run: |
          FAILED=0
          for tfvars in ${{ steps.changed.outputs.tfvars_files }}; do
            echo "--- Checking JMX metrics: $tfvars"
            scripts/check_jmx_metrics.sh --tfvars "$tfvars" || FAILED=1
          done
          exit $FAILED
```
Verify YAML parses: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/preflight.yml')); print('yaml ok')"` (if PyYAML is missing, `python3 -m json.tool` obviously won't work on YAML — fall back to visually diffing indentation against the S3 step).

- [ ] **Step 4: Update CLAUDE.md's Preflight Checks section**

Current first sentence:
```markdown
`scripts/check_ec2_mem_metric.sh`, `scripts/check_asg_metrics.sh`, and `scripts/check_s3_metrics.sh` verify that prerequisite CloudWatch metrics exist before alarms are applied.
```
Replace with:
```markdown
`scripts/check_ec2_mem_metric.sh`, `scripts/check_asg_metrics.sh`, `scripts/check_s3_metrics.sh`, and `scripts/check_jmx_metrics.sh` verify that prerequisite CloudWatch metrics exist before alarms are applied (the JMX check matters most: both JMX alarms treat missing data as notBreaching, so a host without the cwagent JMX config would otherwise sit green forever).
```

- [ ] **Step 5: Commit**

```bash
git add scripts/check_jmx_metrics.sh .github/workflows/preflight.yml CLAUDE.md
git commit -m "feat(preflight): add JMX jvm.* metric check for jmx_resources"
```

---

### Task 9: Doc accuracy fixes (F9)

**Files:**
- Modify: `CLAUDE.md` (EFS bullet, JMX bullet)
- Modify: `cwagent/jmx/README.md` (dimension notes)

- [ ] **Step 1: Fix the "only metric-math alarm" claim**

In `CLAUDE.md`'s EFS bullet:
```
The single `throughput_util` alarm is the repo's only **metric-math** alarm:
```
Replace with:
```
The single `throughput_util` alarm was the repo's first **metric-math** alarm (the JMX module's `heap_used`/`gc_time` are also metric-math):
```

- [ ] **Step 2: Fix the appended-dimensions claim in CLAUDE.md**

In the JMX bullet:
```
That `{InstanceId}` rollup is what lets the `{InstanceId}`-only queries match even though the agent appends extra dimensions (ImageId/InstanceType/ProcessGroupName);
```
Replace with:
```
That `{InstanceId}` rollup is what lets the `{InstanceId}`-only queries match even though the full-dimension JMX series carry extras the receiver adds itself (per-collector `name`, `ProcessGroupName` — the config's `append_dimensions` adds only `InstanceId`);
```

- [ ] **Step 3: Fix the dimension notes in `cwagent/jmx/README.md`**

(a) In the "## Verify metrics are flowing" intro, the parenthetical:
```
(carrying
whatever you appended — `InstanceId`, `ProcessGroupName`, and optionally `ImageId`/
`InstanceType`/`AutoScalingGroupName`) **and** a series with **only `InstanceId`**
```
Replace with:
```
(carrying
`InstanceId` plus dimensions the JMX receiver adds itself, e.g. `ProcessGroupName` and a
per-collector `name` on the GC metrics) **and** a series with **only `InstanceId`**
```

(b) The blockquote:
```
> Dimension notes: `InstanceId` is all the alarms/dashboard need (they hit the rollup), so
> `ImageId`/`InstanceType` in `append_dimensions` are optional — drop them to cut metric
> cardinality/cost if you like; it won't affect the alarms. The `{InstanceId}` rollup also
```
Replace with:
```
> Dimension notes: `InstanceId` is all the alarms/dashboard need (they hit the rollup).
> The shipped config appends only `InstanceId`; adding `ImageId`/`InstanceType` to
> `append_dimensions` is possible but just raises metric cardinality/cost without
> affecting the alarms. The `{InstanceId}` rollup also
```
(The rest of the blockquote — multi-JVM aggregation note — is accurate; keep it.)

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md cwagent/jmx/README.md
git commit -m "docs(jmx,efs): correct metric-math and appended-dimension claims"
```

---

### Task 10: Final sweep

**Files:** none new — formatting and verification only.

- [ ] **Step 1: Format everything**

```bash
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
  sh -c "terraform fmt -recursive"
git status --short
```
Expected: ideally no output from fmt. If fmt rewrote files, inspect `git diff` — only whitespace/alignment changes are acceptable.

- [ ] **Step 2: Validate every touched module once more**

```bash
for m in modules/cloudwatch/metrics-alarm/efs modules/cloudwatch/metrics-alarm/jmx modules/cloudwatch/dashboard/jmx; do
  cd "$m"
  podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
    sh -c "terraform init -backend=false -input=false >/dev/null && terraform validate" || exit 1
  cd - >/dev/null
done
cd stacks/projects/billing/dev
podman run --rm -v "$PWD":/work:Z -w /work docker.io/hashicorp/terraform:1.10 \
  sh -c "terraform fmt -check"
cd -
```
Expected: three `Success! The configuration is valid.` and a silent fmt check.

- [ ] **Step 3: Confirm no stray artifacts and commit any fmt fallout**

```bash
git status --short   # must NOT list .fixture-validate or .terraform anywhere
git diff --stat
```
If fmt changed files:
```bash
git add -u
git commit -m "chore: terraform fmt"
```

- [ ] **Step 4: Cross-check the finding table**

Walk the table at the top of this plan; every row F1–F10 must map to a completed task commit. Then hand back to the human with the branch log:
```bash
git log --oneline main..feat/efs-and-jmx-monitoring | head -15
```
**Do not push and do not merge** — the human reviews first, and real deploys happen on the work machine.
