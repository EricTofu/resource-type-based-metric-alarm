# Implementation Plan & Project Review

**Project:** `resource-type-based-metric-alarm`
**Reviewed:** 2026-04-17
**Status:** Functional MVP, ready for hardening and expansion

---

## 1. Current State

### What's built

- **11 monitoring modules**: ALB, API Gateway, EC2, ASG, Lambda, RDS/Aurora, S3, CloudFront, ElastiCache, OpenSearch, SES
- **DRY pattern**: root `main.tf` iterates per-project resource groups and delegates to per-type modules
- **Per-metric severity maps** (recently refactored from a single default) — e.g. EC2 `StatusCheckFailed` defaults to ERROR while `CPUUtilization` defaults to WARN
- **Three-tier override chain** for thresholds: per-resource override → calculated value (RDS only) → module default variable
- **Severity-based SNS routing**: WARN / ERROR / CRIT → distinct topic ARNs (plus `sns_topic_arns_global` for CloudFront in us-east-1)
- **Aurora Serverless v2 support**: ACUUtilization and ServerlessDatabaseCapacity alarms gated on a `serverless = true` flag
- **RDS cluster expansion**: cluster identifiers are expanded into member instance alarms via `data.aws_rds_cluster`
- **Auto-calculated RDS thresholds**: FreeableMemory and DatabaseConnections derived from instance-class RAM maps
- **Validator scripts** (`scripts/`): shell scripts invoked via `null_resource` provisioners to warn when prerequisite CloudWatch metrics are missing (EC2 mem, ASG, S3 request metrics)
- **Alarm naming convention**: `{Project}-{ResourceType}-[{ResourceName}]-{MetricName}` with severity-prefixed descriptions

### Spec compliance

All metrics defined in `resource-type-based-metric-alarm.md` are implemented. CloudFront was added beyond the spec.

---

## 2. Gaps and Issues

Ordered by blast radius / impact.

### P0 — Correctness risks

1. **No `validation` blocks on severity / SNS ARN inputs.** If a user supplies `severity = "warn"` (lowercase) or a typo, Terraform fails at apply time with an opaque "key not found in map" error. Same for unexpected RDS engines — `local.engine_max_connections_multiplier[engine]` raises if the engine isn't in the map (the current `coalesce` fallback only fires when the value is null, not when the key is missing).
2. **EC2 `data.aws_instance` by Name tag is fragile.** Duplicate or missing Name tags produce cryptic `multiple results` / `no results` errors. No pre-validation, no helpful message.
3. **`null_resource` + `local-exec` provisioners block apply** if the shell script fails, and they only re-run when triggers change. They are not a reliable health check. AWS CLI must be configured identically to the Terraform provider.
4. **No `validation { condition = ... }` on override values** (e.g., thresholds can be negative, percentages > 100).

### P1 — Usability gaps

5. **No outputs.** Modules expose nothing — downstream consumers (dashboards, runbooks) can't reference the created alarm ARNs or names programmatically.
6. **No common-tags variable.** Tags are hardcoded to `Project`, `ResourceType`, `ResourceName`. Teams typically need `Environment`, `Owner`, `CostCenter`, etc.
7. **No alarm-enable toggle.** Can't temporarily silence an alarm (set empty `alarm_actions`) without removing the resource from config.
8. **No `ok_actions` or `insufficient_data_actions`.** Common ops request — notify when an alarm clears.
9. **Evaluation periods / period are hardcoded per module.** Ops teams often tune these per environment (e.g., shorter periods in prod).
10. **CloudFront key is `distribution_id` while other modules key on `name`** — inconsistent. Also has a redundant inline `terraform { required_providers { aws = {...} } }` block that duplicates `versions.tf`.

### P2 — Coverage gaps

11. **Missing resource types**: NAT Gateway, NLB, SQS, ECS service/task, EFS, DynamoDB, Step Functions, Kinesis, MSK, EKS, WAF.
12. **Missing metrics within covered types**:
    - Lambda: `Errors`, `Throttles`, `DeadLetterErrors`, `ConcurrentExecutions` per-function
    - RDS: `DiskQueueDepth`, `ReadLatency`, `WriteLatency`, `ReplicaLag` (Aurora)
    - ALB: `RejectedConnectionCount`, `HTTPCode_ELB_4XX_Count` (optional)
    - S3: `NumberOfObjects` / `BucketSizeBytes` growth
    - EC2: `disk_used_percent` (CWAgent)
13. **No composite alarms.** Would reduce notification noise (e.g., `HostDown = UnHealthyHostCount > 0 AND StatusCheckFailed > 0`).
14. **Single-region assumption.** If resources span regions, the current provider block only supports two (primary + us-east-1). No pattern for N regions.

### P3 — Engineering hygiene

15. **No CI.** No `terraform validate`, `terraform fmt -check`, `tflint`, or `tfsec` pipeline.
16. **No tests.** No Terratest, no example workspace applied in CI against a sandbox account.
17. **No pre-commit hooks.** Format drift will creep in.
18. **Massive copy-paste** inside each module: the `coalesce(try(...), default)` pattern for name/description/severity-action is repeated 4–10× per module. Extracting a `locals` block per resource (pre-computing the resolved severity and description once) would cut each module by ~30%.
19. **Scripts directory is undocumented.** `scripts/*.sh` is not mentioned in README or CLAUDE.md. Dependencies (AWS CLI, credentials, region resolution from AZ) are implicit.
20. **No CHANGELOG / no module versioning.** Modules are source-local, so not strictly required, but adding `# Module version` headers helps teams track which version they vendored.

---

## 3. Proposed Roadmap

Four phases. Each phase stands alone and is independently shippable.

### Phase 1 — Harden the existing surface (1–2 days)

Goal: Make the current modules safer and more self-documenting without changing public API.

- [ ] **Add `validation` blocks** to root `variables.tf` for:
  - `sns_topic_arns` keys (WARN/ERROR/CRIT) present and ARN-shaped
  - per-resource `overrides.severity` ∈ {WARN, ERROR, CRIT} when set
  - threshold values ≥ 0 (or within 0–100 for `*_percent` fields)
- [ ] **RDS engine fallback fix**: change `local.engine_max_connections_multiplier[engine]` to `lookup(..., engine, local.default_engine_multiplier)` so unknown engines don't crash.
- [ ] **EC2 name-tag preflight**: replace the silent `data.aws_instance` failure with a `precondition` block that emits a readable error.
- [ ] **De-duplicate override resolution** per module: add a `locals` block that pre-computes `resolved_severity`, `resolved_description`, `resolved_action` per resource and reference those in each alarm. ~30% line reduction, easier to review.
- [ ] **Remove redundant `terraform` block** from `modules/monitor-cloudfront/main.tf`; it's already in root `versions.tf`.
- [ ] **Document `scripts/`** in README — what each script validates, prerequisites, how to disable.

**Exit criteria:** `terraform validate` + `terraform fmt -check` clean. All modules have at least one `validation` block on accepted inputs. A typo in severity fails at `plan` time with a readable message.

### Phase 2 — Expose outputs & tagging (0.5–1 day)

Goal: Make the project composable with the rest of an org's Terraform.

- [ ] **Per-module `outputs.tf`** exposing:
  - `alarm_arns` (map of metric_key → ARN)
  - `alarm_names` (map of metric_key → name)
- [ ] **Root `outputs.tf`** re-exporting per-project, per-type maps.
- [ ] **Add `common_tags` variable** at root; merge into every alarm's `tags` in every module.
- [ ] **Add `enabled` optional flag** per resource that, when false, sets `alarm_actions = []` (alarm still exists for visibility but doesn't page).

**Exit criteria:** A downstream module can `module.this.alarm_arns["project1-EC2-web-server-1-CPUUtilization"]` and get back an ARN.

### Phase 3 — Expand coverage (2–4 days; parallelizable)

Prioritize by what the team actually runs. Suggested order based on common footprints:

- [ ] **Lambda: add `Errors`, `Throttles`, `DeadLetterErrors`** (same module, new alarms)
- [ ] **RDS: add `ReadLatency`, `WriteLatency`, `DiskQueueDepth`, `ReplicaLag`**
- [ ] **New module: `monitor-sqs`** (ApproximateAgeOfOldestMessage, ApproximateNumberOfMessagesVisible, NumberOfMessagesSent anomaly)
- [ ] **New module: `monitor-ecs`** (CPU/Memory utilization, RunningTaskCount vs DesiredCount)
- [ ] **New module: `monitor-dynamodb`** (UserErrors, SystemErrors, ThrottledRequests, ConsumedCapacity vs provisioned)
- [ ] **New module: `monitor-nat-gateway`** (ErrorPortAllocation, PacketsDropCount, BytesOutToDestination anomaly)

Each new module follows the established pattern. Add example blocks to `terraform.tfvars.example` as modules land.

**Exit criteria:** Each new module plus its variables documented in README's metrics table; example tfvars entry added; new tests (see Phase 4) cover the module.

### Phase 4 — CI, tests, and docs (1–2 days)

- [ ] **GitHub Actions workflow** (or equivalent) running: `terraform fmt -check -recursive`, `terraform validate`, `tflint`, `tfsec` / `checkov`.
- [ ] **Pre-commit config** (`.pre-commit-config.yaml`) wrapping the same checks.
- [ ] **Terratest suite** (optional but high-value): spin up a sandbox AWS account workspace, apply a minimal fixture, assert alarm ARNs exist.
- [ ] **Architectural diagram** in README (mermaid): root → per-type module → per-metric alarm → SNS topic.
- [ ] **`docs/ADDING_A_RESOURCE_TYPE.md`**: step-by-step guide for extending coverage (expanding on the CLAUDE.md section).
- [ ] **`CHANGELOG.md`**: start tracking module-level changes.

**Exit criteria:** CI green on main; a new contributor can add a resource type by following docs alone.

---

## 4. Optional / Longer-term

- **Composite alarms** module (reduces noise; requires identifying alarm ARNs, so depends on Phase 2 outputs).
- **Multi-region pattern**: document or implement a `regions = ["ap-northeast-1", "us-east-1"]` variable with provider-for-each — probably via a thin wrapper that instantiates the module per region.
- **Anomaly detection alarms** for metrics where static thresholds are hard (e.g., request rate, ingress bytes).
- **CloudWatch dashboards** generated from the same resource lists, using the same project/severity metadata.
- **`ok_actions` / `insufficient_data_actions`** support via optional variables.
- **Import helper**: a script that takes a list of existing manually-created alarms and emits tfvars entries, to migrate legacy state.

---

## 5. Risks / Things to Watch

- **Alarm churn during refactor.** Renaming any alarm (e.g., changing resource keys) causes Terraform to destroy+create, which triggers a transient OK→INSUFFICIENT_DATA→ALARM flicker. Batch changes and coordinate with on-call.
- **SNS topic cross-account/region ARNs.** The root validation should allow cross-account ARNs since an org may centralize SNS in one account.
- **Terraform state size.** Each project creates 10–40 alarms per module. 50 projects × 5 modules = thousands of alarms. State operations (`plan`) will slow down; consider state splitting (one workspace per project group) before that becomes painful.
- **IAM permissions.** Data sources need read permissions across all covered services. Document the minimum required policy.

---

## 6. Quick Reference: Effort Sizing

| Phase | Estimate | Parallelizable? | Risk |
| --- | --- | --- | --- |
| 1. Harden | 1–2 days | Mostly yes | Low |
| 2. Outputs & tags | 0.5–1 day | Yes | Low |
| 3. Coverage expansion | 2–4 days (per module ~0.5d) | Yes, per-module | Medium — scope creep |
| 4. CI & docs | 1–2 days | CI and docs independent | Low |

**Total minimum:** ~5 days of focused work to reach a production-hardened, well-documented v1.
