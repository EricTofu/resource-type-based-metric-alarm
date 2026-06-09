# tfvars → config.yaml Wiring Guide (local reference)

> **Status:** local reference / runbook. Lives in `docs/`, which is in the
> **"Never sync"** set of the work-repo sync pattern — it will NOT auto-port to
> `<work>`. Carry it by hand, or do the edits directly on the work env using
> this as the recipe. The companion **`config.yaml.example`** sits in the leaf
> (`stacks/projects/billing/dev/`), which IS synced.

## Why

Org mandate: no `*.tfvars` in git. That blanks out the committed source of
truth for "what to deploy" (the `*_resources` lists) and silently breaks
`preflight.yml` (its trigger path `stacks/projects/**/terraform.tfvars` can
never appear in a PR). Fix: declare deploy intent in a committed **`config.yaml`**
per leaf, read it with `yamldecode`. YAML is not a `*.tfvars`, so the mandate is
satisfied; renaming a tfvars wouldn't help anyway because `-var-file` requires a
`.tfvars`/`.tfvars.json` extension.

The key property that makes this safe: the **library modules**
(`modules/cloudwatch/metrics-alarm/<type>`) already declare the full
`optional()` types AND the `validation` blocks on their `resources` variable.
Passing raw `yamldecode` output into a module coerces it at that boundary —
filling every default (`overrides={}`, `disabled_alarms=[]`, `enabled=true`,
`is_cluster=false`) and running every validation. So the leaf re-declaring those
types is redundant; we delete it.

---

## Per-leaf edits

Do these in each `stacks/projects/<project>/<env>/` leaf. Order doesn't matter;
run `terraform validate` at the end.

### 1. New file: `config.tf` (decode the YAML once)

```hcl
locals {
  cfg = yamldecode(file("${path.module}/config.yaml"))
  res = try(local.cfg.resources, {})
}
```

`local.cfg` holds the scalar wiring; `local.res` holds the per-type lists.
`try(..., {})` keeps a leaf with no `resources:` block from erroring.

### 2. `main.tf` — module calls: `var.*` → `local.*`

Each module block changes in three spots: `count`, `resources`, and the scalar
inputs (`project`, `common_tags`, and lambda's concurrency inputs). `sns_topic_arns`
stays as `local.sns_topic_arns` — that comes from remote state (see §5), not the
YAML, and does NOT change.

**Before:**
```hcl
module "alb_alarms" {
  source         = "../../../../modules/cloudwatch/metrics-alarm/alb"
  count          = length(var.alb_resources) > 0 ? 1 : 0
  project        = var.project
  resources      = var.alb_resources
  sns_topic_arns = local.sns_topic_arns
  common_tags    = var.common_tags
}
```

**After:**
```hcl
module "alb_alarms" {
  source         = "../../../../modules/cloudwatch/metrics-alarm/alb"
  count          = length(try(local.res.alb, [])) > 0 ? 1 : 0
  project        = local.cfg.project
  resources      = try(local.res.alb, [])
  sns_topic_arns = local.sns_topic_arns
  common_tags    = local.cfg.common_tags
}
```

The mechanical mapping for every block:

| Old | New |
|---|---|
| `length(var.<type>_resources) > 0` | `length(try(local.res.<key>, [])) > 0` |
| `resources = var.<type>_resources` | `resources = try(local.res.<key>, [])` |
| `project = var.project` | `project = local.cfg.project` |
| `common_tags = var.common_tags` | `common_tags = local.cfg.common_tags` |
| `sns_topic_arns = local.sns_topic_arns` | *(unchanged)* |

where `<key>` is the type without the `_resources` suffix (`alb_resources` → `alb`,
`apigateway_resources` → `apigateway`, …).

**Lambda block** has two extra scalar inputs — map them with `try` so the YAML
keys stay optional:
```hcl
module "lambda_alarms" {
  source                    = "../../../../modules/cloudwatch/metrics-alarm/lambda"
  count                     = length(try(local.res.lambda, [])) > 0 ? 1 : 0
  project                   = local.cfg.project
  resources                 = try(local.res.lambda, [])
  sns_topic_arns            = local.sns_topic_arns
  common_tags               = local.cfg.common_tags
  concurrency_threshold     = try(local.cfg.lambda_concurrency_threshold, 900)
  concurrency_alarm_enabled = try(local.cfg.lambda_concurrency_alarm_enabled, true)
}
```

**CloudFront block** is unchanged in structure — it keys on `distribution_id`
inside each entry (handled by the library module) and uses the `us_east_1`
provider + `local.sns_topic_arns_global`. Only the `count`/`resources`/`project`/
`common_tags` lines change, same as the table above (`local.res.cloudfront`).

### 3. `data.tf` — remote-state config: `var.*` → `local.cfg.*`

The `terraform_remote_state.platform` block reads scalars that now live in YAML:

```hcl
data "terraform_remote_state" "platform" {
  backend = "s3"
  config = {
    bucket       = local.cfg.ops_bucket          # was var.ops_bucket
    key          = "${local.cfg.env}/platform/sns.tfstate"  # was var.env
    region       = local.cfg.aws_region          # was var.aws_region
    role_arn     = local.cfg.ops_state_role_arn  # was var.ops_state_role_arn
    encrypt      = true
    use_lockfile = true
  }
}

# locals { sns_topic_arns = ... } block stays exactly as-is.
```

> `local.cfg` (from `config.tf`) and the `locals` block here can coexist — Terraform
> merges multiple `locals` blocks. Keep them in separate files for clarity, or fold
> `config.tf`'s locals into `data.tf`.

### 4. `providers.tf` — `var.aws_region` → `local.cfg.aws_region`

```hcl
provider "aws" {
  region = local.cfg.aws_region                  # was var.aws_region
  assume_role {
    role_arn = data.terraform_remote_state.platform.outputs.accounts[local.cfg.env].tf_deployer_role_arn
  }                                              # var.env → local.cfg.env
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  assume_role {
    role_arn = data.terraform_remote_state.platform.outputs.accounts[local.cfg.env].tf_deployer_role_arn
  }
}
```

> A provider may read a `local` sourced from `file()` — `file()`/`yamldecode`
> resolve during init/plan, before provider configuration is needed.

### 5. `variables.tf` — delete the now-dead variables

- **Delete all `variable "<type>_resources"` blocks** — the library modules own
  those types now (~250–300 lines for the billing leaf).
- **Delete the scalar variables** that are now read from YAML: `project`, `env`,
  `aws_region`, `ops_bucket`, `ops_state_role_arn`, `common_tags`,
  `lambda_concurrency_threshold`, `lambda_concurrency_alarm_enabled`.
- If a deleted scalar var carried a `validation` you want to keep (e.g.
  `sns_choice ∈ {create, import}`), move it to a top-level `check` block (any
  `.tf` file in the leaf):

```hcl
check "config_valid" {
  assert {
    condition     = contains(["create", "import"], try(local.cfg.sns_choice, "create"))
    error_message = "config.yaml: sns_choice must be \"create\" or \"import\"."
  }
}
```

After this step the leaf should have **zero `variable` blocks** (unless you keep
one for a genuine secret injected via `TF_VAR_*` — none exist today).

### 6. `.gitignore` (leaf) & example file

- Remove the `terraform.tfvars` line from the leaf `.gitignore` — there's no
  tfvars anymore. `config.yaml` is meant to be committed, so do NOT add it.
- Replace `terraform.tfvars.example` with `config.yaml.example` (already added in
  this leaf as the template).

---

## CI / scripts edits (once, repo-wide)

### `preflight.yml`
- Trigger: `paths: stacks/projects/**/terraform.tfvars` → `stacks/projects/**/config.yaml`.
- `dorny/paths-filter` filter: same path swap.
- This is what un-breaks the workflow — the new path can actually appear in a PR.

### `scripts/check_*.sh` (ec2 / asg / s3)
Swap the brittle Python-regex tfvars parsing for `yq`, and `--tfvars` → `--config`:

```bash
REGION=$(yq -r '.aws_region' "$CONFIG")

# names, skipping entries that opt this metric out via disabled_alarms
NAMES=$(yq -r '
  .resources.ec2[]
  | select((.overrides.disabled_alarms // []) | index("memory") | not)
  | .name' "$CONFIG")
```

Adjust the list key (`ec2`/`asg`/`s3`) and the `disabled_alarms` member per
script. Install `yq` in the workflow step if not already present.

### `scripts/migrate/scaffold-leaf.sh`
Make it emit `config.yaml` instead of `terraform.tfvars` for new leaves.

### `terraform-ci.yml`
**No change.** It runs `validate`/`fmt`/`lint` with `-backend=false` and never
read tfvars.

---

## Remove vs reconfigure

| Remove | Reconfigure |
|---|---|
| `terraform.tfvars` files | `preflight.yml` trigger → `config.yaml` |
| Leaf `*_resources` variable blocks | `check_*.sh`: regex → `yq`, `--tfvars` → `--config` |
| Leaf scalar variable blocks | `scaffold-leaf.sh` → emit YAML |
| Leaf `.gitignore: terraform.tfvars` line | `main.tf` module calls: `var.*` → `local.*` |
| `*.tfvars.example` | `data.tf` / `providers.tf` scalars: `var.*` → `local.cfg.*` |
| `-var-file` from any apply step | — |

---

## Verify on the work env

1. `terraform validate` on a leaf — passes with `config.yaml` present.
2. Negative check: set a bad `severity: WARNING` (or a bogus `disabled_alarms`
   id) in `config.yaml` and confirm `terraform validate` **errors** — proves the
   library-module validations fire through the `yamldecode` path.
3. `terraform plan` with no `-var-file` produces the same resource set the old
   tfvars did (diff the plan against a known-good baseline if you have one).
