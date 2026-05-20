# Per-Metric Alarm Toggle — Design

Date: 2026-05-21
Branch: refactor/m1-m6
Status: Approved for planning

## Problem

Today a project's tfvars controls *which modules* deploy (a non-empty `<type>_resources`
list instantiates the module; an empty list skips it) but not *which metrics inside a
module* deploy. Every metric defined in a module fires for every listed resource. When a
project does not need a specific metric — or the underlying metric does not exist (e.g.
EC2 `mem_used_percent` without the CloudWatch Agent) — there is no way to skip just that
one alarm short of removing the whole resource.

## Goal

Give each project per-resource control over which metric alarms are created, without
breaking any existing project's coverage.

## Decisions

- **Disable semantics: skip creation.** A disabled metric's `aws_cloudwatch_metric_alarm`
  is not created (`for_each` filter), so there is no CloudWatch alarm cost and no console
  clutter. Trade-off: re-enabling later starts the alarm's history fresh. This is distinct
  from the existing per-resource `enabled` flag, which keeps the alarm but mutes
  notifications (`alarm_actions = []`); both are kept and serve different purposes.
- **Toggle shape: a single `disabled_alarms` set of metric IDs**, not N booleans. Keeps the
  schema compact as modules grow. A `validation` block enumerates each module's valid IDs.
- **Default policy: opt-out (all on).** Empty `disabled_alarms` = every metric on, matching
  today's behavior. This is the dominant convention for alarm libraries (fail toward more
  coverage) and means zero migration for existing tfvars.
- **Location: per-resource**, inside each resource's `overrides`. Resources of the same type
  in one project can differ.
- **Scope: all 11 modules.**

## Schema

Add to each module's `overrides` object in `variables.tf`:

```hcl
overrides = optional(object({
  # ...existing fields (severity, description, *_threshold)...
  disabled_alarms = optional(set(string), [])
}), {})
```

Add one validation block per module listing that module's valid metric IDs, e.g. for EC2:

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

### Valid metric IDs per module

| Module | Metric IDs |
|---|---|
| alb | elb_5xx, target_5xx, unhealthy_host, target_response_time |
| apigateway | error_5xx |
| asg | in_service_capacity |
| cloudfront | error_4xx, error_5xx, origin_latency, cache_hit_rate |
| ec2 | status_check, status_check_ebs, cpu, memory |
| elasticache | cpu, memory |
| lambda | duration *(concurrency handled separately — see Special Cases)* |
| opensearch | cpu, jvm_memory, old_gen_jvm, free_storage |
| rds | freeable_memory, cpu, database_connections, free_storage, engine_uptime, read_latency, write_latency, acu_utilization, serverless_capacity |
| s3 | error_5xx *(replication handled separately — see Special Cases)* |
| ses | bounce_rate |

The metric IDs match the `default_severities` map keys and the alarm resource labels in each
module's `main.tf`. RDS `volume_bytes_used` appears in the severities map but its alarm block
is commented out, so it is excluded from the valid set until re-enabled.

## Module-side mechanics

Each per-resource alarm filters disabled metrics out of its `for_each`:

```hcl
resource "aws_cloudwatch_metric_alarm" "memory" {
  for_each = {
    for k, v in local.ec2_resources : k => v
    if !contains(coalesce(try(v.overrides.disabled_alarms, []), []), "memory")
  }
  # ...unchanged...
}
```

- **RDS clusters**: `overrides` already propagates to expanded cluster members
  (`rds/main.tf` cluster-expansion local), so a cluster's `disabled_alarms` applies to all
  its instances automatically.
- **RDS serverless metrics** (`acu_utilization`, `serverless_capacity`): the disabled-check
  is ANDed onto the existing `if v.serverless` filter.

## Special cases

1. **S3 replication stays a separate opt-in gate.** `replication_enabled` defaults *false*
   and is opt-*in*, because `OperationsFailedReplication` only exists when replication is
   configured. It is NOT folded into the opt-out `disabled_alarms`. For S3, `disabled_alarms`
   covers only `error_5xx`; `replication_enabled` continues to gate the replication alarm.
2. **Lambda concurrency is module-level, not per-resource.** `ClaimedAccountConcurrency` is
   an account-level alarm (`count = length(var.resources) > 0 ? 1 : 0`, no resource key), so
   it cannot live in a resource's `overrides`. Add a module input
   `concurrency_alarm_enabled = optional(bool, true)` and gate its `count` on that.
3. **Preflight scripts** (`check_ec2_mem_metric.sh`, `check_asg_metrics.sh`,
   `check_s3_metrics.sh`) parse tfvars and warn when a prerequisite metric is missing. They
   must skip a resource's metric when it is listed in `disabled_alarms`, otherwise CI warns
   about a metric the operator intentionally dropped.

## Migration & compatibility

Zero migration. Every toggle defaults to all-on; existing tfvars are untouched and produce
identical plans. No state moves. `replication_enabled` semantics are unchanged.

## Testing

- `terraform validate` per module (`init -backend=false`) and `terraform fmt -recursive`.
- Validation negative test: `disabled_alarms = ["bogus"]` must fail validation.
- Plan-based proof on `stacks/projects/billing/dev`: set `disabled_alarms = ["memory"]` on an
  EC2 resource and confirm the memory alarm drops from the plan.
  - Caveat: requires AWS credentials and platform remote state; may only be runnable on the
    work machine, not in this environment.

## Documentation

- Update `CLAUDE.md` module-pattern section to describe `disabled_alarms`.
- Add a commented `disabled_alarms` example to `terraform.tfvars.example`.
- Document the `disabled_alarms` field (and `concurrency_alarm_enabled` for Lambda) in the
  module `variables.tf` descriptions.

## Out of scope

- Changing the existing per-resource `enabled` (mute) semantics.
- A type-level / project-wide default toggle (per-resource only for now).
- Re-enabling RDS `volume_bytes_used`.
