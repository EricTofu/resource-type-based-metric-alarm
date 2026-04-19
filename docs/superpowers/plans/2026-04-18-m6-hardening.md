# M6: Hardening + Synthetics-Canary Module — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Work through the P0/P1 hardening items from `IMPLEMENTATION_PLAN.md` (now that the library is its own thing post-M1/M2/M3/M4), move preflight scripts out of `null_resource` and into CI, wire a CI pipeline, and add the new `modules/cloudwatch/synthetics-canary/` library module (Goal #6 of the spec).

**Architecture:**
- Each hardening item is independent and can ship as its own PR. Do NOT batch — a regression in one item is painful to untangle from the others.
- All `.tf` edits happen inside `modules/cloudwatch/metrics-alarm/<type>/` (library) — no more root to touch.
- Library changes must be backward-compatible per the spec Non-goals ("Changing alarm thresholds, metrics, or severity defaults"). Add optional fields; don't rename or remove existing ones.
- CI runs against every stack (`stacks/foundation/ops`, `stacks/platform/<alias>`, `stacks/services/<service>/<alias>`) with `fmt -check`, `validate`, `tflint`, `tfsec`. A matrix strategy keeps it parallel.
- `synthetics-canary` follows the metrics-alarm pattern: one sub-module per use case (HTTP heartbeat, API happy-path) with the same `project`/`resources`/`sns_topic_arns` variable shape.

**Tech Stack:** Terraform ≥ 1.10, AWS provider ≥ 5.0, GitHub Actions, tflint, tfsec, bash.

**Prerequisites:**
- M4 complete. Repo root has no `.tf` files; every stack uses the library at `modules/cloudwatch/metrics-alarm/<type>/`.
- At least one `stacks/services/*/*/` leaf is applied and stable; it'll be the smoke-test target after each item lands.

---

## Inputs to fill before executing

| Token | Meaning | Example |
|---|---|---|
| `<SMOKE_LEAF>` | Path to an applied, stable leaf for post-change verification | `stacks/services/billing/dev` |
| `<TFSEC_OR_CHECKOV>` | Pick one security scanner; other item is skipped | `tfsec` |

---

## Per-task pattern

Each task below follows the same shape:
1. Make the change in the library module (or CI, or new module).
2. Run `terraform fmt -recursive` across the repo.
3. In `<SMOKE_LEAF>`, run `terraform init -upgrade=false && terraform plan -detailed-exitcode`. Expect exit `0` — the change must be zero-diff.
4. Commit.

Only Task 7 (CI wiring) and Task 10 (synthetics-canary) produce non-zero diffs; those are noted explicitly.

---

## Task 1: Add `validation` blocks to library module inputs — P0

Each library module currently accepts a typed `resources` list; what it does NOT do is validate values at plan time. A typo like `severity = "warn"` passes the type check but blows up at `apply` as `key "warn" not found in map`. `validation {}` catches this at `plan`.

Applies to all 11 library modules. The `severity` validator is the one non-trivial piece; thresholds are simple numeric `>= 0` checks.

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/alb/variables.tf`
- Modify: `modules/cloudwatch/metrics-alarm/apigateway/variables.tf`
- Modify: `modules/cloudwatch/metrics-alarm/asg/variables.tf`
- Modify: `modules/cloudwatch/metrics-alarm/cloudfront/variables.tf`
- Modify: `modules/cloudwatch/metrics-alarm/ec2/variables.tf`
- Modify: `modules/cloudwatch/metrics-alarm/elasticache/variables.tf`
- Modify: `modules/cloudwatch/metrics-alarm/lambda/variables.tf`
- Modify: `modules/cloudwatch/metrics-alarm/opensearch/variables.tf`
- Modify: `modules/cloudwatch/metrics-alarm/rds/variables.tf`
- Modify: `modules/cloudwatch/metrics-alarm/s3/variables.tf`
- Modify: `modules/cloudwatch/metrics-alarm/ses/variables.tf`

- [ ] **Step 1: Add severity validation to every module's `resources` variable**

For each module's `variables.tf`, append to the `resources` variable block:

```hcl
validation {
  condition = alltrue([
    for r in var.resources :
    try(r.overrides.severity, null) == null
    || contains(["WARN", "ERROR", "CRIT"], r.overrides.severity)
  ])
  error_message = "overrides.severity must be one of WARN, ERROR, CRIT (case-sensitive) or omitted."
}
```

- [ ] **Step 2: Add `sns_topic_arns` ARN-shape validation**

Every module has a `sns_topic_arns` variable of shape `object({WARN=string, ERROR=string, CRIT=string})`. Append:

```hcl
validation {
  condition = alltrue([
    for k in ["WARN", "ERROR", "CRIT"] :
    can(regex("^arn:aws:sns:", var.sns_topic_arns[k]))
  ])
  error_message = "sns_topic_arns values must be SNS ARNs (starting with arn:aws:sns:)."
}
```

- [ ] **Step 3: Add non-negative threshold validation per module**

In each module's `resources` variable, add validators for every numeric override field. Generic shape for one field:

```hcl
validation {
  condition = alltrue([
    for r in var.resources :
    try(r.overrides.cpu_threshold, null) == null || try(r.overrides.cpu_threshold, 0) >= 0
  ])
  error_message = "overrides.cpu_threshold must be non-negative or omitted."
}
```

Repeat this block per threshold field per module (EC2 has `cpu_threshold`, `memory_threshold`; RDS has 10+ fields; etc.). For `*_percent` fields, also assert `<= 100`:

```hcl
validation {
  condition = alltrue([
    for r in var.resources :
    try(r.overrides.freeable_memory_threshold_percent, null) == null
    || (try(r.overrides.freeable_memory_threshold_percent, 0) >= 0
        && try(r.overrides.freeable_memory_threshold_percent, 0) <= 100)
  ])
  error_message = "overrides.freeable_memory_threshold_percent must be between 0 and 100 inclusive, or omitted."
}
```

- [ ] **Step 4: Fmt, smoke-plan, commit**

```bash
terraform fmt -recursive
cd <SMOKE_LEAF>
terraform plan -detailed-exitcode   # expect exit 0
cd <REPO_ROOT>
git add modules/cloudwatch/metrics-alarm/
git commit -m "feat(library): Add input validation to all metrics-alarm modules.

Validators cover (1) overrides.severity in {WARN,ERROR,CRIT}, (2)
sns_topic_arns values matching ^arn:aws:sns:, (3) non-negative numeric
thresholds and 0-100 ranges for *_percent fields. Bad inputs now fail
at plan time with a readable error instead of at apply time with
'key not found in map'."
```

---

## Task 2: RDS engine fallback with `lookup()` — P0

Currently `modules/cloudwatch/metrics-alarm/rds/main.tf` accesses `local.engine_max_connections_multiplier[engine]`. If the engine string isn't a key, Terraform raises a confusing error before `coalesce` ever runs.

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/rds/main.tf`

- [ ] **Step 1: Find the offending references**

Run: `grep -n 'engine_max_connections_multiplier\[' modules/cloudwatch/metrics-alarm/rds/main.tf`

Expected: at least one match using bracket-indexing (`[engine]`).

- [ ] **Step 2: Replace bracket access with `lookup()`**

For each match, change:

```hcl
local.engine_max_connections_multiplier[engine]
```

to:

```hcl
lookup(local.engine_max_connections_multiplier, engine, local.default_engine_multiplier)
```

- [ ] **Step 3: Add the default constant**

In the same file's `locals {}` block, ensure `default_engine_multiplier` is defined with a conservative value:

```hcl
default_engine_multiplier = 50  # RAM_bytes * 50 = connection cap — matches MySQL default
```

Document the choice in a single-line comment so the next reader knows where `50` came from.

- [ ] **Step 4: Fmt, smoke-plan, commit**

```bash
terraform fmt -recursive
cd <SMOKE_LEAF>
terraform plan -detailed-exitcode   # expect exit 0
cd <REPO_ROOT>
git add modules/cloudwatch/metrics-alarm/rds/
git commit -m "fix(library/rds): Use lookup() for engine_max_connections_multiplier.

Unknown engines (e.g., 'aurora-postgresql-compatible') no longer crash
the module; the default multiplier (matches MySQL) applies."
```

---

## Task 3: EC2 name-tag preconditions — P0

`data.aws_instance` silently returns garbage on duplicate or missing Name tags. A `precondition` makes the failure obvious and actionable.

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/ec2/main.tf`

- [ ] **Step 1: Add a preconditions-only data source**

Above the existing `data "aws_instance" "this"` block, add a separate `data "aws_instances" "by_name"` (plural — returns a list, not a single instance) and a `check {}` block that asserts exactly one match:

```hcl
data "aws_instances" "by_name" {
  for_each = local.ec2_resources

  filter {
    name   = "tag:Name"
    values = [each.value.name]
  }

  filter {
    name   = "instance-state-name"
    values = ["running", "stopped"]
  }
}

check "ec2_name_tag_uniqueness" {
  assert {
    condition = alltrue([
      for k, d in data.aws_instances.by_name : length(d.ids) == 1
    ])
    error_message = "Every EC2 resource must have exactly one running/stopped instance with a matching Name tag. Check: ${join(", ", [for k, d in data.aws_instances.by_name : \"${k}=${length(d.ids)}\" if length(d.ids) != 1])}"
  }
}
```

The `check {}` block raises a plan-time warning rather than hard-failing the apply. That's deliberate: if a team renames an instance in the middle of a deploy, you want the apply to continue (using the existing data.aws_instance.this resolution which may still work) but you want the warning front-and-center.

- [ ] **Step 2: Fmt, smoke-plan, commit**

```bash
terraform fmt -recursive
cd <SMOKE_LEAF>
terraform plan -detailed-exitcode   # expect exit 0 (check blocks don't change the plan)
cd <REPO_ROOT>
git add modules/cloudwatch/metrics-alarm/ec2/
git commit -m "feat(library/ec2): Add Name-tag uniqueness check.

A check{} block asserts each EC2 resource maps to exactly one
instance by Name tag. Duplicates or missing tags surface as a
plan-time warning instead of an opaque 'multiple results' error
at apply."
```

---

## Task 4: Per-module `outputs.tf` — P1

Each library module should expose `alarm_arns` and `alarm_names` maps so downstream consumers (dashboards, runbooks, service leaf outputs) can reference what was created.

Applies to all 11 modules.

**Files:**
- Create: `modules/cloudwatch/metrics-alarm/<type>/outputs.tf` (× 11)

- [ ] **Step 1: Author one template outputs.tf**

Template (adjust the resource list per module — EC2 has 4 alarms, SES has 1, RDS has 8):

```hcl
output "alarm_arns" {
  description = "Map of metric-key → alarm ARN for every alarm created by this module instance."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.status_check     : "${k}:StatusCheckFailed"     => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.status_check_ebs : "${k}:StatusCheckFailed_AttachedEBS" => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.cpu              : "${k}:CPUUtilization"        => v.arn },
    { for k, v in aws_cloudwatch_metric_alarm.memory           : "${k}:mem_used_percent"      => v.arn },
  )
}

output "alarm_names" {
  description = "Map of metric-key → alarm name for every alarm created by this module instance."
  value = merge(
    { for k, v in aws_cloudwatch_metric_alarm.status_check     : "${k}:StatusCheckFailed"     => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.status_check_ebs : "${k}:StatusCheckFailed_AttachedEBS" => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.cpu              : "${k}:CPUUtilization"        => v.alarm_name },
    { for k, v in aws_cloudwatch_metric_alarm.memory           : "${k}:mem_used_percent"      => v.alarm_name },
  )
}
```

Adjust the merged resources per module:
- `alb`: `http_5xx_elb`, `http_5xx_target`, `unhealthy_host`, `target_response_time`
- `apigateway`: `error_5xx`
- `asg`: `capacity`
- `cloudfront`: `error_4xx`, `error_5xx`, `origin_latency`, `cache_hit_rate`
- `ec2`: `status_check`, `status_check_ebs`, `cpu`, `memory` (above)
- `elasticache`: `cpu`, `memory`
- `lambda`: `duration`, `concurrency` (plus the singleton account-concurrency alarm; include it with key `"account:ClaimedAccountConcurrency"`)
- `opensearch`: `cpu`, `jvm_memory`, `old_gen_jvm_memory`, `free_storage`
- `rds`: `freeable_memory`, `cpu`, `database_connections`, `free_storage`, `engine_uptime`, `volume_bytes_used`, `acu_utilization`, `serverless_capacity`
- `s3`: `error_5xx`, `replication_failed`
- `ses`: `bounce_rate`

- [ ] **Step 2: Iterate through each module**

For each of the 11 modules:

```bash
MODULE=<type>
$EDITOR modules/cloudwatch/metrics-alarm/$MODULE/outputs.tf
# create the file with the adjusted merge() call per the list above
```

- [ ] **Step 3: Update leaf stack outputs to actually use these**

The stack `stacks/services/<service>/<alias>/outputs.tf` already has `try(module.<type>_alarms[0].alarm_arns, [])`. After this task lands, the `try()` returns a real map instead of `[]`.

No stack edits required — the `try()` handles both shapes.

- [ ] **Step 4: Fmt, smoke-plan, commit**

```bash
terraform fmt -recursive
cd <SMOKE_LEAF>
terraform plan -detailed-exitcode   # expect exit 0
terraform apply                      # expect "0 to add, 0 to change, 0 to destroy" — outputs are computed values
cd <REPO_ROOT>
git add modules/cloudwatch/metrics-alarm/
git commit -m "feat(library): Expose alarm_arns and alarm_names per module.

Every metrics-alarm module now outputs two maps keyed by
'<resource-key>:<metric-name>'. Leaf stacks already have
try() wrappers that consume these; no leaf edits required."
```

---

## Task 5: `common_tags` variable across every module — P1

Teams commonly tag alarms with `Environment`, `Owner`, `CostCenter`, etc. Currently the tags are hardcoded to three fields. Add an optional `common_tags` variable that merges in.

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/<type>/variables.tf` (× 11)
- Modify: `modules/cloudwatch/metrics-alarm/<type>/main.tf` (× 11)
- Modify: `stacks/services/<service>/<alias>/variables.tf` (per leaf — can add later)
- Modify: `stacks/services/<service>/<alias>/main.tf` (per leaf — can add later)

- [ ] **Step 1: Add the variable to every module**

In each module's `variables.tf`:

```hcl
variable "common_tags" {
  description = "Tags merged into every alarm resource this module creates. Module-specific tags (Project, ResourceType, ResourceName) always take precedence on key collision."
  type        = map(string)
  default     = {}
}
```

- [ ] **Step 2: Merge into every alarm's `tags` block**

For every `aws_cloudwatch_metric_alarm.*` resource in each module, change:

```hcl
tags = {
  Project      = var.project
  ResourceType = "EC2"
  ResourceName = each.value.name
}
```

to:

```hcl
tags = merge(
  var.common_tags,
  {
    Project      = var.project
    ResourceType = "EC2"
    ResourceName = each.value.name
  }
)
```

Module-specific tags come second so they win on key collision (matches the docstring).

- [ ] **Step 3: Plumb through leaf stacks (optional; add as services opt in)**

In `stacks/services/<service>/<alias>/variables.tf`, add:

```hcl
variable "common_tags" {
  description = "Tags applied to every alarm in this stack."
  type        = map(string)
  default     = {}
}
```

In `stacks/services/<service>/<alias>/main.tf`, pass `common_tags = var.common_tags` into every `module "<type>_alarms"` call.

You can defer leaf-side plumbing until a team actually needs tags. The module default `{}` means the alarms stay bit-identical until someone sets `common_tags`.

- [ ] **Step 4: Fmt, smoke-plan, commit**

```bash
terraform fmt -recursive
cd <SMOKE_LEAF>
terraform plan -detailed-exitcode   # expect exit 0
cd <REPO_ROOT>
git add modules/cloudwatch/metrics-alarm/
git commit -m "feat(library): Add common_tags variable to every metrics-alarm module.

Optional map merged into each alarm's tags. Module-specific tags
(Project, ResourceType, ResourceName) win on collision. Default {} is
zero-diff for existing deployments."
```

---

## Task 6: Per-resource `enabled` flag — P1

Temporarily silencing an alarm without deleting its config: support `enabled = false` which sets `alarm_actions = []` (the alarm still exists and reports to CloudWatch, but SNS notifications are suppressed).

Applies to all 11 modules.

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/<type>/variables.tf` (× 11) — add optional `enabled` field inside the `resources` object
- Modify: `modules/cloudwatch/metrics-alarm/<type>/main.tf` (× 11) — gate `alarm_actions`

- [ ] **Step 1: Add the field to every module's `resources` type**

In each module's `variables.tf`, inside the `resources` list object type, add:

```hcl
enabled = optional(bool, true)
```

Place it adjacent to `name` / `overrides` for readability.

- [ ] **Step 2: Gate `alarm_actions` in every alarm**

For every `aws_cloudwatch_metric_alarm.*` in each module, change:

```hcl
alarm_actions = [
  var.sns_topic_arns[coalesce(
    try(each.value.overrides.severity, null),
    local.default_severities.cpu
  )]
]
```

to:

```hcl
alarm_actions = each.value.enabled ? [
  var.sns_topic_arns[coalesce(
    try(each.value.overrides.severity, null),
    local.default_severities.cpu
  )]
] : []
```

The ternary short-circuits; when `enabled = false`, no ARN lookup happens either — safer against misconfig.

- [ ] **Step 3: Fmt, smoke-plan, commit**

```bash
terraform fmt -recursive
cd <SMOKE_LEAF>
terraform plan -detailed-exitcode   # expect exit 0 (default is true)
cd <REPO_ROOT>
git add modules/cloudwatch/metrics-alarm/
git commit -m "feat(library): Add optional 'enabled' flag per resource.

enabled = false sets alarm_actions = [] so the alarm still exists and
publishes to CloudWatch but sends no SNS notifications. Default true
keeps existing deployments bit-identical."
```

---

## Task 7: Move preflight scripts from `null_resource` to CI — P1

`null_resource` + `local-exec` inside `terraform apply` is fragile: AWS CLI must be on PATH, must have the same credentials, and any failure blocks the whole apply. Move the checks to a pre-apply CI step; delete the `null_resource` blocks.

Applies to EC2, ASG, and S3 modules (per grep of current `null_resource` usage).

**Files:**
- Modify: `modules/cloudwatch/metrics-alarm/ec2/main.tf` (delete `null_resource.check_mem_metric`)
- Modify: `modules/cloudwatch/metrics-alarm/asg/main.tf` (delete similar block)
- Modify: `modules/cloudwatch/metrics-alarm/s3/main.tf` (delete similar block)
- Create: `.github/workflows/preflight.yml`
- Keep: `scripts/check_ec2_mem_metric.sh`, `scripts/check_asg_metric.sh`, `scripts/check_s3_request_metrics.sh` — called from CI now

- [ ] **Step 1: Remove `null_resource` blocks from each module**

Grep first:

```bash
grep -rn 'null_resource' modules/cloudwatch/metrics-alarm/
```

For each hit, delete the full `resource "null_resource" "..." { ... }` block (including `provisioner "local-exec" { command = ... }` and any `triggers = { ... }`).

- [ ] **Step 2: Remove null provider references**

If any `modules/cloudwatch/metrics-alarm/<type>/versions.tf` declares `null = { ... }` under `required_providers`, remove that entry. If it declares only `null`, consider deleting the file entirely — the stack's `versions.tf` covers the rest.

- [ ] **Step 3: Write the CI preflight workflow**

Create `.github/workflows/preflight.yml`:

```yaml
name: Preflight — metric-prereq checks

on:
  pull_request:
    paths:
      - 'stacks/services/**/terraform.tfvars'
      - 'scripts/check_*.sh'

jobs:
  check-ec2-mem-metric:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Configure AWS creds (read-only)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.PREFLIGHT_READ_ROLE_ARN }}
          aws-region: ap-northeast-1
      - name: Run EC2 mem-metric preflight
        run: |
          for tfvars in stacks/services/*/*/terraform.tfvars; do
            scripts/check_ec2_mem_metric.sh --tfvars "$tfvars"
          done

  check-asg-metric:
    runs-on: ubuntu-latest
    needs: check-ec2-mem-metric
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.PREFLIGHT_READ_ROLE_ARN }}
          aws-region: ap-northeast-1
      - run: |
          for tfvars in stacks/services/*/*/terraform.tfvars; do
            scripts/check_asg_metric.sh --tfvars "$tfvars"
          done

  check-s3-request-metrics:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.PREFLIGHT_READ_ROLE_ARN }}
          aws-region: ap-northeast-1
      - run: |
          for tfvars in stacks/services/*/*/terraform.tfvars; do
            scripts/check_s3_request_metrics.sh --tfvars "$tfvars"
          done
```

`PREFLIGHT_READ_ROLE_ARN` is a new IAM role in the target accounts with read-only CloudWatch / EC2 / S3 permissions. Adding it is out of scope for this plan — track it as a follow-up issue before turning this workflow on.

- [ ] **Step 4: Update the preflight scripts to accept `--tfvars`**

Each script currently takes AZ+instance-id (for EC2) or bucket name (for S3) as positional args. Refactor to accept `--tfvars <path>` and iterate internally. Concrete edits depend on each script's existing shape — keep changes minimal, reusing most of the existing logic.

- [ ] **Step 5: Document in CLAUDE.md**

Add a "Preflight checks" section to `CLAUDE.md` noting the CI workflow, the role secret, and how to run the scripts locally.

- [ ] **Step 6: Fmt, smoke-plan, commit**

```bash
terraform fmt -recursive
cd <SMOKE_LEAF>
terraform plan -detailed-exitcode
# Expect: a set of 'to destroy' entries, one per null_resource that previously existed.
# Review: these are the deletions intended by this task. Apply:
terraform apply
cd <REPO_ROOT>
git add .github/workflows/preflight.yml modules/cloudwatch/metrics-alarm/ scripts/ CLAUDE.md
git commit -m "feat(ci): Move preflight metric checks from null_resource to CI.

Deletes null_resource + local-exec provisioners from ec2, asg, and s3
modules. Adds a GitHub Actions workflow that runs the same shell
scripts against every stacks/services/*/*/terraform.tfvars on PRs
touching those files. scripts/check_*.sh now accept --tfvars and
iterate the resource list themselves.

Post-apply in every leaf: N null_resource instances are destroyed
(state-only side effect — no AWS resources are affected because
null_resource has no cloud counterpart)."
```

- [ ] **Step 7: Apply the same cleanup to every applied leaf**

Each leaf will show `X to destroy` (the null_resource instances) on next plan. Apply each one:

```bash
for leaf in stacks/services/*/*/; do
  echo "--- $leaf ---"
  (cd "$leaf" && terraform plan -detailed-exitcode) || (cd "$leaf" && terraform apply -auto-approve)
done
```

Safe because `null_resource` has no AWS side effect on destruction.

---

## Task 8: CI pipeline for every stack — P1

One GitHub Actions workflow that runs `fmt -check`, `validate`, `tflint`, and `<TFSEC_OR_CHECKOV>` against every stack on every PR.

**Files:**
- Create: `.github/workflows/terraform-ci.yml`
- Create: `.tflint.hcl`

- [ ] **Step 1: Write the tflint config**

Create `.tflint.hcl` at the repo root:

```hcl
plugin "aws" {
  enabled = true
  version = "0.31.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

config {
  format           = "compact"
  force            = false
  disabled_by_default = false
}

rule "terraform_required_version" { enabled = true }
rule "terraform_required_providers" { enabled = true }
rule "terraform_standard_module_structure" { enabled = true }
```

- [ ] **Step 2: Write the CI workflow**

Create `.github/workflows/terraform-ci.yml`:

```yaml
name: Terraform CI

on:
  pull_request:

jobs:
  detect-stacks:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.detect.outputs.matrix }}
    steps:
      - uses: actions/checkout@v4
      - id: detect
        run: |
          stacks=$(find stacks -name versions.tf -printf '%h\n' | sort | jq -R . | jq -cs .)
          echo "matrix=$stacks" >> "$GITHUB_OUTPUT"

  fmt-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: 1.10.0 }
      - run: terraform fmt -check -recursive

  validate:
    runs-on: ubuntu-latest
    needs: [detect-stacks]
    strategy:
      fail-fast: false
      matrix:
        stack: ${{ fromJson(needs.detect-stacks.outputs.matrix) }}
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: 1.10.0 }
      - working-directory: ${{ matrix.stack }}
        run: |
          terraform init -backend=false
          terraform validate

  tflint:
    runs-on: ubuntu-latest
    needs: [detect-stacks]
    strategy:
      fail-fast: false
      matrix:
        stack: ${{ fromJson(needs.detect-stacks.outputs.matrix) }}
    steps:
      - uses: actions/checkout@v4
      - uses: terraform-linters/setup-tflint@v4
        with: { tflint_version: latest }
      - run: tflint --init
      - working-directory: ${{ matrix.stack }}
        run: tflint

  tfsec:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: aquasecurity/tfsec-action@v1.0.3
        with:
          soft_fail: false
          working_directory: .
```

Swap `tfsec` for `checkov` if `<TFSEC_OR_CHECKOV> = checkov` — minor syntax difference, same semantics.

- [ ] **Step 3: Fmt, push a throwaway PR, confirm all jobs pass**

```bash
terraform fmt -recursive
git add .github/workflows/terraform-ci.yml .tflint.hcl
git commit -m "feat(ci): Add Terraform CI workflow (fmt, validate, tflint, tfsec).

Runs fmt -check once and validate/tflint per stack via a detected
matrix. tfsec covers the whole repo. Fails PRs on any violation."
git push -u origin HEAD:ci-smoke-test
# open the PR, watch the checks run, confirm all green, merge or close
```

- [ ] **Step 4: Fix anything the CI flags**

Realistically, `tflint` and `tfsec` will flag a handful of things on first run. Triage per-finding:
- Real bugs (missing `description`, missing `required_version`): fix the module.
- False positives or style-only noise: add to `.tflint.hcl` `rule "..." { enabled = false }` with a one-line reason comment.

Commit the triage commit separately.

---

## Task 9: Initial `synthetics-canary` library module — Goal #6

Scaffold `modules/cloudwatch/synthetics-canary/` with parity to `modules/cloudwatch/metrics-alarm/` shape. First version covers only the HTTP heartbeat canary (simplest). Future metrics (API happy-path, multi-step browser) land as additional modules later.

The canary itself is `aws_synthetics_canary`; the alerting side is `aws_cloudwatch_metric_alarm` on its standard `SuccessPercent` metric.

**Files:**
- Create: `modules/cloudwatch/synthetics-canary/heartbeat/versions.tf`
- Create: `modules/cloudwatch/synthetics-canary/heartbeat/variables.tf`
- Create: `modules/cloudwatch/synthetics-canary/heartbeat/main.tf`
- Create: `modules/cloudwatch/synthetics-canary/heartbeat/outputs.tf`
- Create: `modules/cloudwatch/synthetics-canary/heartbeat/README.md`

- [ ] **Step 1: Create the directory**

Run: `mkdir -p modules/cloudwatch/synthetics-canary/heartbeat`

- [ ] **Step 2: Write `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}
```

- [ ] **Step 3: Write `variables.tf`**

```hcl
variable "project" {
  description = "Service name — used in canary names and tags."
  type        = string
}

variable "resources" {
  description = "List of URLs to canary-check. Each entry produces one canary resource + one SuccessPercent alarm."
  type = list(object({
    name              = string
    url               = string
    frequency_minutes = optional(number, 5)
    timeout_seconds   = optional(number, 30)
    overrides = optional(object({
      severity                  = optional(string)
      description               = optional(string)
      success_percent_threshold = optional(number)
    }), {})
  }))
  default = []

  validation {
    condition = alltrue([
      for r in var.resources :
      try(r.overrides.severity, null) == null
      || contains(["WARN", "ERROR", "CRIT"], r.overrides.severity)
    ])
    error_message = "overrides.severity must be one of WARN, ERROR, CRIT or omitted."
  }

  validation {
    condition = alltrue([for r in var.resources : can(regex("^https?://", r.url))])
    error_message = "Each resources[].url must start with http:// or https://"
  }
}

variable "sns_topic_arns" {
  description = "Map severity → SNS ARN. Same shape as metrics-alarm modules."
  type = object({
    WARN  = string
    ERROR = string
    CRIT  = string
  })
}

variable "artifacts_bucket" {
  description = "S3 bucket that Synthetics uses to store run artifacts. Must already exist in the target account."
  type        = string
}

variable "execution_role_arn" {
  description = "IAM role assumed by the canary. Must already exist with the standard CloudWatchSyntheticsRole policy."
  type        = string
}

variable "default_success_percent_threshold" {
  description = "Alarm triggers when SuccessPercent over the last evaluation window drops below this value."
  type        = number
  default     = 90
}

variable "common_tags" {
  type    = map(string)
  default = {}
}
```

- [ ] **Step 4: Write `main.tf`**

```hcl
locals {
  canaries = { for r in var.resources : r.name => r }

  default_severities = {
    success_percent = "ERROR"
  }

  # Canary runtime version — pin to a supported syn-nodejs-puppeteer release.
  canary_runtime_version = "syn-nodejs-puppeteer-9.1"
}

resource "aws_synthetics_canary" "heartbeat" {
  for_each = local.canaries

  name                 = "${var.project}-${each.value.name}"
  artifact_s3_location = "s3://${var.artifacts_bucket}/${var.project}/${each.value.name}/"
  execution_role_arn   = var.execution_role_arn
  runtime_version      = local.canary_runtime_version
  handler              = "pageLoadBlueprint.handler"

  schedule {
    expression          = "rate(${each.value.frequency_minutes} minute${each.value.frequency_minutes == 1 ? "" : "s"})"
    duration_in_seconds = 0  # run indefinitely
  }

  run_config {
    timeout_in_seconds = each.value.timeout_seconds
    environment_variables = {
      URL = each.value.url
    }
  }

  zip_file = data.archive_file.heartbeat_zip[each.key].output_path

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "SyntheticsCanary"
      ResourceName = each.value.name
    }
  )

  start_canary = true
}

# Canonical heartbeat handler — tiny inline file written per canary.
data "archive_file" "heartbeat_zip" {
  for_each    = local.canaries
  type        = "zip"
  output_path = "${path.module}/.build/${each.value.name}.zip"

  source {
    filename = "nodejs/node_modules/pageLoadBlueprint.js"
    content  = <<-EOT
      const synthetics = require('Synthetics');
      const log = require('SyntheticsLogger');
      exports.handler = async function () {
        const url = process.env.URL;
        await synthetics.executeHttpStep('heartbeat', url);
      };
    EOT
  }
}

resource "aws_cloudwatch_metric_alarm" "success_percent" {
  for_each = local.canaries

  alarm_name        = "${var.project}-Synthetics-[${each.value.name}]-SuccessPercent"
  alarm_description = "[${coalesce(try(each.value.overrides.severity, null), local.default_severities.success_percent)}]-${coalesce(try(each.value.overrides.description, null), \"${var.project}-Synthetics-[${each.value.name}]-SuccessPercent dropped below threshold\")}"

  namespace           = "CloudWatchSynthetics"
  metric_name         = "SuccessPercent"
  statistic           = "Average"
  comparison_operator = "LessThanThreshold"
  threshold           = coalesce(try(each.value.overrides.success_percent_threshold, null), var.default_success_percent_threshold)
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  period              = 300

  dimensions = {
    CanaryName = aws_synthetics_canary.heartbeat[each.key].name
  }

  alarm_actions = [
    var.sns_topic_arns[coalesce(try(each.value.overrides.severity, null), local.default_severities.success_percent)]
  ]

  treat_missing_data = "breaching"

  tags = merge(
    var.common_tags,
    {
      Project      = var.project
      ResourceType = "SyntheticsCanary"
      ResourceName = each.value.name
    }
  )
}
```

- [ ] **Step 5: Write `outputs.tf`**

```hcl
output "canary_arns" {
  description = "Map of canary name → canary ARN."
  value       = { for k, v in aws_synthetics_canary.heartbeat : k => v.arn }
}

output "alarm_arns" {
  description = "Map of canary name → SuccessPercent alarm ARN."
  value       = { for k, v in aws_cloudwatch_metric_alarm.success_percent : k => v.arn }
}

output "alarm_names" {
  description = "Map of canary name → SuccessPercent alarm name."
  value       = { for k, v in aws_cloudwatch_metric_alarm.success_percent : k => v.alarm_name }
}
```

- [ ] **Step 6: Write `README.md`**

Create a short README documenting the module's inputs, the canary runtime version pin, and how to add more canary types later (one new sub-module per use case). Keep it to ~40 lines.

- [ ] **Step 7: Fmt, init, validate, commit**

```bash
terraform fmt -recursive
cd modules/cloudwatch/synthetics-canary/heartbeat
terraform init -backend=false
terraform validate
cd <REPO_ROOT>
git add modules/cloudwatch/synthetics-canary/
git commit -m "feat(library): Add synthetics-canary/heartbeat module.

Creates an HTTP heartbeat canary + SuccessPercent alarm per entry in
resources. Follows metrics-alarm module shape (project, resources,
sns_topic_arns, common_tags). Reserves the path for additional
canary types (api-happy-path, browser-flow) as sub-modules under
modules/cloudwatch/synthetics-canary/."
```

---

## Task 10: Wire `synthetics-canary` into the leaf pattern (optional, per-service)

Only needed for services that actually want canaries. Skip otherwise.

**Files:**
- Modify: `stacks/services/<service>/<alias>/variables.tf` — add canary resource list
- Modify: `stacks/services/<service>/<alias>/main.tf` — call `synthetics-canary/heartbeat`
- Modify: `stacks/services/<service>/<alias>/outputs.tf` — re-export canary ARNs
- Modify: `stacks/services/<service>/<alias>/terraform.tfvars` — fill canary resource list

- [ ] **Step 1: Add canary variables to the leaf**

In `variables.tf`:

```hcl
variable "canary_heartbeat_resources" {
  type = list(object({
    name              = string
    url               = string
    frequency_minutes = optional(number, 5)
    timeout_seconds   = optional(number, 30)
    overrides = optional(object({
      severity                  = optional(string)
      description               = optional(string)
      success_percent_threshold = optional(number)
    }), {})
  }))
  default = []
}

variable "canary_artifacts_bucket" {
  type    = string
  default = ""
}

variable "canary_execution_role_arn" {
  type    = string
  default = ""
}
```

- [ ] **Step 2: Wire the module call**

In `main.tf`:

```hcl
module "canary_heartbeat" {
  source = "../../../../modules/cloudwatch/synthetics-canary/heartbeat"
  count  = length(var.canary_heartbeat_resources) > 0 ? 1 : 0

  project            = local.project
  resources          = var.canary_heartbeat_resources
  sns_topic_arns     = local.sns_topic_arns
  artifacts_bucket   = var.canary_artifacts_bucket
  execution_role_arn = var.canary_execution_role_arn
}
```

- [ ] **Step 3: Re-export canary outputs**

In `outputs.tf`, extend the `alarm_arns` output:

```hcl
output "alarm_arns" {
  value = {
    # … existing metrics-alarm types …
    canary_heartbeat = try(module.canary_heartbeat[0].alarm_arns, {})
  }
}

output "canary_arns" {
  value = try(module.canary_heartbeat[0].canary_arns, {})
}
```

- [ ] **Step 4: Fill tfvars, plan, apply, commit**

Edit the leaf's `terraform.tfvars` to populate `canary_heartbeat_resources`, `canary_artifacts_bucket`, `canary_execution_role_arn`. Then:

```bash
cd stacks/services/<service>/<alias>
terraform plan
# review: canary + alarm resources expected
terraform apply
cd <REPO_ROOT>
git add stacks/services/<service>/<alias>/
git commit -m "feat(services/<service>/<alias>): Wire heartbeat canary.

Adds <N> heartbeat canaries + SuccessPercent alarms from the new
synthetics-canary/heartbeat library module. Alarm SNS routing uses
the same platform topics as metric alarms."
```

---

## Verification summary (M6 complete)

Not every item is required — M6 ships in independent PRs. Per item:

1. **Validation (Task 1):** typo-test a leaf tfvars with `severity = "warn"` → plan fails with the validator's error message.
2. **RDS lookup (Task 2):** set an RDS resource's engine to `"unknown-engine"` in a test tfvars → plan succeeds; the default multiplier is used.
3. **EC2 precondition (Task 3):** rename an instance's Name tag in AWS → next plan surfaces a check warning identifying the key with 0 matches.
4. **Module outputs (Task 4):** `terraform output -raw alarm_arns` in a leaf returns a populated JSON object instead of an empty list.
5. **common_tags (Task 5):** set `common_tags = {Owner = "platform"}` in a leaf tfvars → `aws cloudwatch list-tags-for-resource --resource-arn <alarm>` shows the new tag.
6. **enabled flag (Task 6):** flip one resource's `enabled = false` → plan shows that alarm's `alarm_actions` dropping to `[]`; apply; `aws cloudwatch describe-alarms --alarm-names <alarm>` confirms `AlarmActions: []`.
7. **Preflight in CI (Task 7):** open a PR that edits a leaf's tfvars → the preflight workflow runs and reports per-tfvars check results.
8. **CI pipeline (Task 8):** open a PR with a format violation → fmt-check fails. Fix and re-push; CI green.
9. **synthetics-canary (Task 9/10):** `terraform state list` in a canary-enabled leaf shows both `module.canary_heartbeat[0].aws_synthetics_canary.heartbeat["..."]` and `module.canary_heartbeat[0].aws_cloudwatch_metric_alarm.success_percent["..."]`. SuccessPercent alarm routes to the correct severity SNS topic.

---

## Rollback

Each M6 task is its own commit. `git revert <sha>` plus `terraform plan`/`apply` in affected leaves undoes the change. The null_resource removal in Task 7 is the most "destructive" step, but deleting null_resource has no AWS side effect, so reverting it just re-adds harmless no-op Terraform resources.

---

## Known limitations / edge cases

1. **Validation strictness.** A `contains` check on `overrides.severity` is case-sensitive. If teams already use `"Warn"` somewhere, they'll see a new plan error — document the exact accepted values in the leaf `terraform.tfvars.example` (if one exists) to preempt.
2. **RDS default multiplier value (`50`).** Adjust per organizational standards. The comment in Task 2 Step 3 should reflect actual source.
3. **synthetics-canary runtime pin.** `syn-nodejs-puppeteer-9.1` will age out. Bump deliberately — don't put `runtime_version = "latest"`.
4. **Canary artifact bucket and role pre-existence.** The module expects both to already exist. If your platform layer doesn't provision them yet, add an `aws_s3_bucket` + `aws_iam_role` to `stacks/platform/<alias>/main.tf` first. That's strictly out of scope for this plan (belongs in a platform-plumbing follow-up).
5. **CI role provisioning.** `PREFLIGHT_READ_ROLE_ARN` and any IAM role the Terraform CI uses to `validate`/`plan` need an OIDC trust policy with the GitHub Actions provider. Adding that is a cross-account IAM task, typically done in the foundation stack. Out of scope here; track as a follow-up issue.
6. **Matrix build scope.** Task 8's `detect-stacks` globs `find stacks -name versions.tf`. If you add a stack in a non-standard path, update the `find` command.
7. **Large PR churn from Task 1.** Adding validators to 11 modules is a ~500-line diff — split into 11 PRs (one per module) if that's your team's norm.
