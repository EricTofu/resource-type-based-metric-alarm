# CloudWatch Alarm Project Refactor — Design Spec

- **Date:** 2026-04-18 (revised 2026-04-19)
- **Status:** Draft — pending user review
- **Supersedes the draft at:** `STRUCTURE.md`
- **Related:** `IMPLEMENTATION_PLAN.md` (its Phase 1/2/4 items get folded into M6 here)

---

## Context

The project currently ships CloudWatch alarms for 11 AWS resource types as a **single-root Terraform module** with `modules/monitor-<type>/` children. A single `terraform.tfvars` holds every resource for every service and every environment, keyed by a `project` field.

This works for a small number of resources in a single account. It does not work for the target footprint:

- **Many AWS accounts, one per env tier plus specialty accounts** — dev, stg, prod today, with regional/purpose-specific accounts expected (e.g., `account-prod-apac`, `account-data-prod`). Accounts are identified by a human-readable **alias** (e.g., `account-dev`, `account-stg`, `account-prod-apac`) — aliases are stable, IDs rotate between AWS Organizations exports.
- **A dedicated Ops account holds all Terraform state** (single S3 bucket + KMS CMK). Every other stack reads/writes state there via cross-account role assumption.
- **Per-service state isolation is a hard requirement** (service teams own their alarm lifecycle independently).
- **Multiple services per account** — each account houses multiple services (e.g., `billing`, `checkout` both live in `account-dev`). Each `(service, account)` pair is one Terraform state.
- **≥2 regions** with CloudFront alarms pinned to `us-east-1` via a provider alias; additional regions added per-stack as needed without new directory levels.

The `STRUCTURE.md` draft proposed a refactor but was over-nested (5 levels) for the "no 3rd-party tools (initially)" constraint; that depth multiplies backend/provider boilerplate linearly with the leaf count.

This spec commits to a flatter structure (3 levels) that honors all hard requirements, minimizes duplication at the chosen scale, and is forward-compatible with adopting Terragrunt later if the boilerplate pain ever justifies it.

## Goals

1. Split the monolithic root into a reusable **library** (`modules/cloudwatch/…`) and independent **deployment leaves** (`stacks/…`).
2. One Terraform state per `(service, account-alias)` — grows with accounts and services, no hard ceiling.
3. Centralize state in one Ops-account S3 bucket with SSE-KMS and native S3 locking; leaves cross-account-assume into Ops for state and into the target account for resources.
4. Provide clear conventions for cross-stack references, backend storage, state locking, and account-ID resolution so nothing drifts across N leaves.
5. Produce a migration path that moves existing alarms into new states **without recreating them** (no alarm flicker).
6. Leave room to add new resource types (SQS, ECS, DynamoDB, etc.), a `synthetics-canary` module, and new accounts with no structural changes.
7. Keep Terragrunt adoption as an explicit future checkpoint (not day-one).

## Non-goals

- Adopting Terragrunt, Atlantis, Spacelift, or any orchestrator in the initial refactor.
- Changing alarm thresholds, metrics, or severity defaults (orthogonal; tracked in `IMPLEMENTATION_PLAN.md`).
- Multi-region isolation per service **as the default** (regions are provider aliases inside a single `(service, account)` stack). Per-service exceptions are covered by Open Decision #1.
- A single-pane inventory view built into Terraform (handled by a small out-of-band script).
- Cross-account SNS publishing — SNS topics live in each target account's `platform` stack and are consumed in-account by that account's alarms. No hub-and-spoke topic routing.

---

## Target Architecture

### Directory layout

Two independent axes: the **repo directory** (organized for code authoring) and the **S3 state key** (organized for blast-radius auditing). They're decoupled — the `backend.hcl` per leaf is the glue.

```
repo-root/
├── modules/
│   └── cloudwatch/
│       ├── metrics-alarm/              # library: one leaf per resource type
│       │   ├── alb/        apigateway/ asg/  cloudfront/ ec2/
│       │   ├── elasticache/ lambda/ opensearch/ rds/ s3/ ses/
│       ├── stacks/
│       │   └── standard-alarms/        # composite — extracted ONLY after ≥3 leaves duplicate
│       └── synthetics-canary/          # new module (parity with metrics-alarm)
├── stacks/
│   ├── foundation/
│   │   └── ops/                        # ONE stack in Ops account: state bucket + KMS + cross-account roles
│   ├── platform/
│   │   ├── dev/                        # one stack per target account (alias drops "account-" prefix in code)
│   │   ├── stg/
│   │   ├── prod/
│   │   ├── prod-apac/                  # example of non-1:1 account
│   │   └── data-prod/                  # example of purpose-split account
│   └── services/
│       └── <service>/
│           ├── dev/                    # one leaf per (service, account) pair
│           ├── stg/
│           ├── prod/
│           └── ...
├── docs/superpowers/specs/             # design docs
├── scripts/                            # inventory.sh, smoke/*, preflight helpers
├── README.md
├── CLAUDE.md
└── IMPLEMENTATION_PLAN.md              # complementary hardening roadmap
```

**Naming convention:** the leaf-directory name matches the account alias with the `account-` prefix stripped. `stacks/services/billing/dev/` targets account alias `account-dev`. For a multi-account env tier, aliases include the distinguishing suffix: `stacks/services/billing/prod-apac/` targets `account-prod-apac`.

The repo-root `main.tf`, `variables.tf`, `terraform.tfvars`, and `terraform.tfvars.example` are **removed** in M4 once all services are migrated.

### Library module naming

- Drop the `monitor-` prefix. `modules/monitor-alb/` → `modules/cloudwatch/metrics-alarm/alb/`.
- Each library module:
  - Declares `configuration_aliases` (not `provider` blocks) for any needed regional aliases.
  - Exposes `outputs.tf` with `alarm_arns` and `alarm_names` maps (fulfilling Phase 2 of `IMPLEMENTATION_PLAN.md`).
  - Contains no `null_resource` + `local-exec` provisioners (those move to CI; see §Testing).

### Anatomy of a leaf stack — `stacks/services/<service>/<alias>/`

```
versions.tf           # terraform >= 1.10, aws provider >= 5.0, backend "s3" {}
backend.hcl           # partial backend: bucket, key, region, encrypt, kms_key_id, use_lockfile, role_arn (Ops)
providers.tf          # primary aws + us-east-1 alias; BOTH assume_role into target account via var.target_account_role_arn
variables.tf          # typed inputs: service, target_account_role_arn, ec2_resources, rds_resources, etc.
terraform.tfvars      # actual inventory for this (service, account); NO project field
main.tf               # direct module calls into the library (switches to composite post-M5)
outputs.tf            # re-exports alarm ARNs for dashboards / audits
```

**Two role hops per apply:**

1. **Backend role** (`backend.hcl` → `role_arn`): caller assumes an **Ops-account** role that grants read/write to `s3://<ORG>-tfstate/` and `kms:Encrypt/Decrypt/GenerateDataKey` on the Ops CMK. Used only for state I/O.
2. **Provider role** (`providers.tf` → `assume_role`): caller assumes a **target-account** deploy role with permissions to create CloudWatch alarms, SNS subscriptions, etc. Used for all resource CRUD.

Initialization: `terraform init -backend-config=backend.hcl`. Between leaves, the values that vary are `key` (always) and `role_arn` in `providers.tf` (changes per target account; the backend `role_arn` is the same Ops role everywhere).

Provider blocks live in the **leaf stack**, never in library modules. The leaf passes aliases explicitly: `providers = { aws = aws, aws.us_east_1 = aws.us_east_1 }`.

### Resource inventory schema (per-leaf tfvars)

Drop the `project` field — it's redundant now that each stack is a `(service, account)` pair:

```hcl
# Before (root-level tfvars)
ec2_resources = [
  { project = "billing", resources = [{ name = "billing-web-1" }] }
]

# After (stacks/services/billing/prod/terraform.tfvars)
ec2_resources = [{ name = "billing-web-1" }, { name = "billing-web-2" }]
```

The stack injects `project = var.service` (where `service` is a top-level variable set per leaf) into each module call. Alarm names remain `{service}-{ResourceType}-[{name}]-{MetricName}` — identical if existing `project` values match the service name.

**Optional escape hatch** (YAGNI — ship without, add when first asked): an optional `project` override per resource for sub-grouping like `billing-api` vs `billing-workers`.

---

## Data Flow & Conventions

### Cross-stack references

- **`platform/<alias>` exports SNS topic ARNs** as Terraform outputs, once per target account.
- **`services/<service>/<alias>` consumes them** via `data "terraform_remote_state" "platform"` reading `account-<alias>/platform/sns.tfstate` from the **Ops-account bucket**. The state-read uses the same Ops backend role, so it's cross-account-capable by construction.
- Platform's output schema is a stable contract, documented in `stacks/platform/<alias>/outputs.tf` header.

Rejected alternatives:
- **SSM Parameter Store** — viable but extra infra and ceremony; the centralized state bucket already provides the cross-account data channel at zero marginal cost.
- **Hardcoded ARNs per leaf** — doesn't scale past ~3 leaves.

### State backend conventions

Single bucket in the Ops account. Every stack writes a state file at a hierarchical key that matches its blast-radius boundary.

| Property | Value |
|---|---|
| State bucket | `<ORG>-tfstate` (one bucket total, in the Ops account) |
| State KMS CMK | `alias/tfstate` (one key, in the Ops account) |
| State key — foundation | `foundation/ops.tfstate` |
| State key — platform | `account-<alias>/platform/sns.tfstate` (e.g., `account-dev/platform/sns.tfstate`) |
| State key — services | `account-<alias>/services/<service>/alarms.tfstate` (e.g., `account-prod/services/billing/alarms.tfstate`) |
| State key — future canaries | `account-<alias>/services/<service>/canaries.tfstate` (reserved) |
| Backend `role_arn` | Ops-account cross-account role (same value in every non-foundation leaf's `backend.hcl`) |
| Locking | **S3 native** (`use_lockfile = true`) — no DynamoDB |
| Terraform version | **≥ 1.10** (required for native locking) |
| Encryption | SSE-KMS with the single Ops-account CMK |

**Why account-alias-first in the key (not env-first):**
- Not all tiers are 1:1 with a single account (e.g., prod + prod-apac both exist).
- Aliases are the IAM blast-radius boundary; grouping state keys by alias makes `aws s3 ls --recursive | grep '^account-prod'` return exactly what's in prod accounts.
- Tier-level audits use substring match (`grep prod`), which is fine — the naming convention enforces consistency.

### Auth & cross-account roles

Two roles, both pre-provisioned by `foundation/ops` (or by the human operator bootstrapping Ops if Ops is managed elsewhere):

1. **Ops `tf-state-access` role** (lives in Ops account) — assumed by every leaf's backend. Permissions:
   - `s3:GetObject`, `PutObject`, `ListBucket`, `DeleteObject` on `<ORG>-tfstate` (path-scoped per caller where practical).
   - `kms:Encrypt`, `Decrypt`, `GenerateDataKey`, `DescribeKey` on the state CMK.
   - Trust policy: allow sts:AssumeRole from specific target-account deploy roles (or, initially, from specific human users / CI identities).

2. **Target-account `tf-deployer` role** (lives in each target account — dev, stg, prod, prod-apac, …) — assumed by every leaf's AWS provider. Permissions scoped to what the stack creates (CloudWatch alarms, SNS topics for platform stacks, read-only lookups for data sources).

**Account-ID mapping** lives in one place: `stacks/foundation/ops/outputs.tf` (or a top-level `accounts.auto.tfvars` if Ops is managed outside this repo). Output shape:

```hcl
output "accounts" {
  value = {
    "account-dev"        = { id = "111111111111", tf_deployer_role_arn = "arn:aws:iam::111111111111:role/tf-deployer" }
    "account-stg"        = { id = "222222222222", tf_deployer_role_arn = "arn:aws:iam::222222222222:role/tf-deployer" }
    "account-prod"       = { id = "333333333333", tf_deployer_role_arn = "arn:aws:iam::333333333333:role/tf-deployer" }
    "account-prod-apac"  = { id = "444444444444", tf_deployer_role_arn = "arn:aws:iam::444444444444:role/tf-deployer" }
  }
  description = "Alias → account metadata. Consumed by every leaf stack via terraform_remote_state."
}

output "tf_state_access_role_arn" {
  value = "arn:aws:iam::<OPS_ACCOUNT_ID>:role/tf-state-access"
}
```

Every leaf consumes this via `data "terraform_remote_state" "foundation"` and wires both role ARNs into its provider + backend config. This keeps account IDs out of every leaf's `backend.hcl` / `providers.tf` except via one indirection.

### Apply ordering (runbook, not tooling)

1. `foundation/ops` — **once, ever** (creates the Ops state bucket + KMS CMK + `tf-state-access` role + publishes the `accounts` output). Bootstrapped via local-state → `-migrate-state`.
2. `platform/<alias>` — one per target account; creates SNS topics. Each is independent; parallel-safe.
3. `services/<service>/<alias>` — parallel-safe across (service, account) pairs; within a service, apply dev → stg → prod serially for safety.

Ordering dependencies are only *between* layers (1 → 2 → 3). Within a layer, all leaves are independent.

### Inventory document — `scripts/inventory.sh`

~20-line bash script that:
- Iterates `stacks/services/*/*/terraform.tfvars`.
- Extracts `ec2_resources`, `rds_resources`, etc.
- Emits a consolidated markdown/CSV report at `docs/inventory.md` (CI artifact on every PR).
- Replaces the single-pane visibility lost by splitting tfvars.

A complementary `scripts/smoke/audit-alarms.sh` queries AWS directly for an "actually deployed" view.

---

## Migration Path

Six phases. Each phase is one PR with explicit rollback. No big-bang rewrite.

### M0 — Bootstrap (additive)

**Blocked on:** Ops account existing (provisioned out-of-band). Until that lands, M0 can be drafted and reviewed but not applied.

Split into two substeps:

- **M0a — foundation/ops (one-time):** Create `stacks/foundation/ops/` — a single stack that provisions, in the Ops account, the `<ORG>-tfstate` S3 bucket (versioned + SSE-KMS + lifecycle + public-access-blocked), the `alias/tfstate` KMS CMK, and the `tf-state-access` cross-account role. Bootstrap with local state → apply → `terraform init -migrate-state` into the bucket it just created. Publish the `accounts` map and `tf_state_access_role_arn` as outputs (per the §Auth section).
- **M0b — platform/\<alias\> (one per target account):** Create `stacks/platform/<alias>/` for each active account alias (start with `dev`, `stg`, `prod`; add `prod-apac` etc. when those accounts are commissioned). Each stack uses the Ops-bucket backend from the start — no local-state dance needed because M0a already produced the bucket. Two SNS choices per account:
  - **Create fresh topics** and repoint the old root's `sns_topic_arns` tfvar to the new ARNs for whichever account the root is currently aimed at, OR
  - **Import existing topics** via `import {}` blocks if the target account already has topics the team depends on.
- **Risk:** zero — old root is untouched throughout M0.

### M1 — Library refactor (zero-diff)

- `git mv modules/monitor-<type>/ modules/cloudwatch/metrics-alarm/<type>/` (strip `monitor-` prefix).
- Update old root `main.tf` `source` paths.
- **Verification:** `terraform plan` in the old root produces zero diff in every env. Commit only if that holds.

### M2 — First service cutover (pilot: billing × dev)

State-split using Terraform 1.7+ `removed` + `import` blocks — no manual `terraform state mv`. This crosses an account boundary (old root's state lives wherever the current team runs `terraform apply`; new leaf's state lives in Ops), so both the old root and the new leaf are configured with the appropriate backend before the split.

1. **Snapshot** — `terraform state pull > backups/pre-billing-dev.tfstate`.
2. **Create leaf** — `stacks/services/billing/dev/` targeting account alias `account-dev`. Tfvars for billing only (no `project` field). Backend writes to `s3://<ORG>-tfstate/account-dev/services/billing/alarms.tfstate` via the Ops `tf-state-access` role; provider assumes the `account-dev` deploy role.
3. **Add `import` blocks** in new stack for each existing billing alarm, e.g.:
   ```hcl
   import {
     to = module.ec2_alarms.aws_cloudwatch_metric_alarm.cpu["billing-web-1"]
     id = "billing-EC2-[billing-web-1]-CPUUtilization"
   }
   ```
4. **Add `removed` blocks** in old root for the same resources:
   ```hcl
   removed {
     from = module.monitor_ec2["billing"]
     lifecycle { destroy = false }
   }
   ```
5. **Apply order:** new leaf first (`terraform apply` — imports, zero diff after), then old root (applies the `removed` — state-only).
6. **Verify:** `aws cloudwatch describe-alarms | jq '.MetricAlarms[] | .AlarmConfigurationUpdatedTimestamp'` — timestamps predate the cutover.
7. **Cleanup:** delete the single-use `import`/`removed` blocks in a follow-up commit.

Generator script (`scripts/migrate/generate-split.sh`, ~40 lines) reads tfvars + current state and emits the `import.tf`/`removed.tf` pair. Writing this script first saves hours across N cutovers.

**Pilot rule:** M2 for billing × `account-dev` must be stable for ~24h before proceeding to billing × `account-stg` → billing × `account-prod`.

### M3 — Remaining service cutovers

Same pattern as M2. Parallel across (service, account) pairs; serial `dev → stg → prod` within a service.

### M4 — Decommission old root

- Verify old root state is empty.
- Delete root `main.tf`, `variables.tf`, `terraform.tfvars*`.
- Archive old state backups for 30 days, then delete.

### M5 — Extract `standard-alarms` composite

**Not started until ≥3 stacks have been in prod ≥1 week.** Extraction is a zero-diff refactor per stack.

### M6 — Hardening (independent PRs)

Pulled from `IMPLEMENTATION_PLAN.md`:
- Input `validation` blocks (severity, ARN, thresholds) — P0.
- RDS `lookup()` fallback for unknown engines — P0.
- EC2 Name-tag precondition — P0.
- Per-module `outputs.tf` — P1.
- `common_tags` + per-resource `enabled` flag — P1.
- Move preflight scripts from `null_resource` provisioners to CI jobs. Delete runtime `scripts/` coupling.
- CI pipeline (`fmt -check`, `validate`, `tflint`, `tfsec`).

### Timeline ballpark

Effort assumes `N_accounts ≈ 3–5` and `N_services ≈ 5`. Scales linearly with `N_accounts × N_services`.

| Phase | Effort | Parallelizable |
|---|---|---|
| M0a foundation/ops | ~0.5 day | no (one stack, one apply) |
| M0b platform/<alias> × N_accounts | ~0.5 day × N_accounts | across accounts |
| M1 library move | ~2 hours | no |
| M2 pilot (billing × account-dev → stg → prod) | ~1 day | serial within service |
| M3 remaining ((N_services − 1) × N_accounts cutovers) | ~0.5 day per (service, account) | across (service, account) pairs |
| M4 decommission | ~2 hours | no |
| M5 composite extraction | ~1 day | after stability |
| M6 hardening (10 items) | ~3–5 days | yes |
| **Total (3 accounts × 5 services)** | **~11–14 engineer-days** | |

### Safety nets (enforced every PR)

1. Pre-migration state snapshot in `backups/` (retained 30 days).
2. `terraform plan -detailed-exitcode` — exit 2 fails any "refactor-only" PR.
3. Alarm-creation-timestamp audit post-apply confirms no unintended recreates.
4. Rollback recipe in PR description: `terraform state push backups/…`, `git revert <sha>`, `terraform apply`.

---

## Testing & CI

### Pre-merge checks (per PR)

- `terraform fmt -check -recursive` (built-in)
- `terraform validate` in each affected leaf (built-in)
- `terraform plan -detailed-exitcode` — exit 2 fails refactor-only PRs (built-in)
- `tflint --recursive` (OSS, static analysis — different category from Terragrunt, propose allowing)
- `tfsec` or `checkov` (pick one; OSS; security misconfig)
- `scripts/inventory.sh --validate` — flags resources declared in 2+ services

### Per-apply gates

- `terraform plan -out=tfplan.bin`
- `terraform show -json tfplan.bin | jq` — human review of any `delete`/`replace`.
- Any `replace` on `aws_cloudwatch_metric_alarm` requires explicit approval.
- `terraform apply tfplan.bin` applies the exact reviewed plan.

### Post-apply smoke (per service, new env)

- Alarm count matches tfvars expectations.
- `AlarmActions` resolves to correct platform SNS ARN.
- Severity→topic mapping correct across WARN/ERROR/CRIT.
- (Optional) `aws cloudwatch set-alarm-state` forces a test notification through to Slack/email.

### Deferred

- Terratest / `terraform test` for library modules — worth adopting post-M5, off the critical path.
- End-to-end integration tests across platform → services — `terraform_remote_state` contract is the integration surface; plan failures are sufficient at this scale.

---

## Committed Decisions (summary table)

| # | Decision |
|---|---|
| 1 | Layout: `modules/cloudwatch/{metrics-alarm,stacks,synthetics-canary}/` + `stacks/{foundation/ops,platform/<alias>,services/<service>/<alias>}/`. |
| 2 | Per-`(service, account-alias)` state. One state file per leaf; scales with accounts × services. Regions as provider aliases inside each leaf. |
| 3 | **Single Ops-account S3 bucket** (`<ORG>-tfstate`) holds all state. Key schema is `account-<alias>/…`-first to mirror the IAM blast-radius boundary. |
| 4 | **Two-role-hop auth.** Backend assumes Ops `tf-state-access`; provider assumes target-account `tf-deployer`. Account-ID map published as a `foundation/ops` output and consumed via `terraform_remote_state`. |
| 5 | Drop `monitor-` prefix; library at `metrics-alarm/<type>/`. |
| 6 | Drop `project` field from per-service tfvars; service name injected by stack. |
| 7 | Cross-stack refs: `terraform_remote_state` reading `account-<alias>/platform/sns.tfstate` from the Ops bucket. |
| 8 | S3 native locking (TF ≥1.10), no DynamoDB. |
| 9 | Partial backend config via `backend.hcl` + `-backend-config=…`. |
| 10 | Composite `standard-alarms` extracted only after ≥3 stacks prove duplication. |
| 11 | Preflight scripts move from `null_resource` to CI. |
| 12 | Terragrunt documented as future checkpoint; not adopted in initial refactor. |
| 13 | Inventory via `scripts/inventory.sh`. |
| 14 | Account alias convention: `account-<tier>[-<qualifier>]` (e.g., `account-dev`, `account-prod-apac`). Repo directory drops the `account-` prefix (`stacks/services/billing/dev/`); S3 key keeps it (`account-dev/services/billing/alarms.tfstate`). |

---

## Open Decisions (non-blocking; resolve before M2)

1. **Regional boundary per service.** Default is provider aliases inside the leaf. Any service with substantially different resource sets per region may want its own `(service, account, region)` leaves. Needs per-service review.
2. **`tflint` / `tfsec` allowed under "no 3rd-party tools"?** They're static analysis, not orchestration. Recommended yes; needs explicit decision.
3. **`project` override kept or dropped?** YAGNI says drop entirely, add later when first sub-grouping need arises.
4. **Smoke tests — required in CI forever, or only during migration?** Recommend: required for prod applies, optional for dev/stg post-M3.
5. **Ops account ownership.** Is `foundation/ops/` managed by this repo, or does an upstream platform/SRE team manage Ops and we only consume its outputs? If upstream: we skip M0a and instead read the `accounts` map from their `terraform_remote_state` (or an equivalent data contract). Must be resolved before starting M0.

---

## Next Step (not executed by this doc)

Once this spec is user-approved, invoke the `superpowers:writing-plans` skill to translate it into an executable implementation plan with task-level granularity. Implementation begins from the resulting plan, not from this spec.
