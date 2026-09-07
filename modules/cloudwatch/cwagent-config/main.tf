#------------------------------------------------------------------------------
# CloudWatch Agent config → SSM Parameter Store, one parameter per host group.
#
# This is the EMITTING half of the identity contract the alarm modules query:
# every other module asks CloudWatch for series matching
# `<cwagent_dimension_key> = '<value>'`; this module decides what the agent
# stamps. Both sides read the same stack variable.
#
# Each config is BASE ⊕ PROJECT OVERLAY ⊕ IDENTITY:
#
#   templates/base.json.tftpl   what every Linux host reports — cpu, mem, disk,
#                               net, swap, processes — and nothing app-specific.
#   <template_dir>/<template>   what the APP is: its `logs` and its `jmx` block,
#                               plus any host-metric departure from the base.
#   identity                    stamped on afterwards, by this module
#
# ⚠ Terraform's write ends at Parameter Store. Applying a change here does NOT
#   restart any agent and does NOT re-publish any metric: until each host
#   re-fetches, the series keep the OLD dimension values. In that window every
#   CWAgent-sourced alarm (ASG memory/disk, JMX heap/GC) matches nothing and sits
#   notBreaching — green, not red.
#------------------------------------------------------------------------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

locals {
  name_prefix = coalesce(var.parameter_name_prefix, "AmazonCloudWatch-${var.project}-${var.env}-")

  configs = { for c in var.configs : c.name => c }

  # One variable set for both templates. templatefile() ignores vars a template
  # does not use, so an overlay needing no substitution is still a valid .tftpl.
  # `name` is what lets two host groups share one overlay file and still write
  # distinct log group names.
  tpl_vars = { for k, c in local.configs : k => {
    project             = var.project
    env                 = var.env
    name                = c.name
    collection_interval = var.metrics_collection_interval
    dimension_key       = var.cwagent_dimension_key
    dimension_value     = c.cwagent_dimension_value
    process_group       = c.process_group == null ? "" : c.process_group
  } }

  # An entry with no overlay renders templates/empty.json.tftpl rather than a
  # literal {}: both branches must be a path, because a conditional cannot return
  # two differently-shaped objects.
  overlay_dir  = coalesce(var.template_dir, path.module)
  overlay_path = { for k, c in local.configs : k => c.template == null ? "${path.module}/templates/empty.json.tftpl" : "${local.overlay_dir}/${c.template}" }

  base    = { for k, c in local.configs : k => jsondecode(templatefile("${path.module}/templates/base.json.tftpl", local.tpl_vars[k])) }
  overlay = { for k, c in local.configs : k => jsondecode(templatefile(local.overlay_path[k], local.tpl_vars[k])) }

  #----------------------------------------------------------------------------
  # MERGE. merge() is SHALLOW and this document is deep: a plain
  # merge(base, overlay) would replace the whole `metrics` block with the
  # overlay's, silently dropping every plugin the base defines. So the depths are
  # spelled out — top level, `metrics`, and `metrics_collected` — and stop there:
  # a plugin the overlay names is replaced WHOLE, never field-merged.
  #----------------------------------------------------------------------------
  plugins_merged = { for k, c in local.configs : k => merge(
    try(local.base[k].metrics.metrics_collected, {}),
    try(local.overlay[k].metrics.metrics_collected, {}),
  ) }

  # `"ethtool": null` in an overlay drops a base plugin. `"//"` keys are the
  # overlays' comment idiom (JSON has none) — dropped here, before one is mistaken
  # for a plugin and stamped with a dimension.
  plugins_kept = { for k, v in local.plugins_merged : k => { for pk, pv in v : pk => pv if pv != null && !startswith(pk, "//") } }

  #----------------------------------------------------------------------------
  # IDENTITY STAMP. No template writes the fleet dimension; this does, on every
  # plugin, after the merge. So a plugin an overlay replaces — or invents — is
  # compliant by construction, and cannot become the one series no alarm matches.
  # Both maps are map(string) so the conditional below has one consistent type.
  #----------------------------------------------------------------------------
  dims = { for k, c in local.configs : k => tomap({ (var.cwagent_dimension_key) = c.cwagent_dimension_value }) }
  jmx_dims = { for k, c in local.configs : k => tomap(merge(
    { (var.cwagent_dimension_key) = c.cwagent_dimension_value },
    c.process_group == null ? {} : { ProcessGroupName = c.process_group },
  )) }

  # A plugin value is either an object (mem, disk, …) or a list of them (jmx,
  # procstat). jsonencode is the discriminator — a JSON array starts with "[" —
  # because the two shapes cannot share a branch of a conditional.
  plugins = { for k, c in local.configs : k => merge(
    {
      for pk, pv in local.plugins_kept[k] : pk => merge(pv, {
        append_dimensions = merge(try(pv.append_dimensions, {}), pk == "jmx" ? local.jmx_dims[k] : local.dims[k])
      }) if substr(jsonencode(pv), 0, 1) != "["
    },
    {
      for pk, pv in local.plugins_kept[k] : pk => [
        for e in pv : merge(e, {
          append_dimensions = merge(try(e.append_dimensions, {}), pk == "jmx" ? local.jmx_dims[k] : local.dims[k])
        })
      ] if substr(jsonencode(pv), 0, 1) == "["
    },
  ) }

  merged = { for k, c in local.configs : k => merge(
    local.base[k],
    local.overlay[k],
    {
      agent = merge(try(local.base[k].agent, {}), try(local.overlay[k].agent, {}))
      metrics = merge(
        try(local.base[k].metrics, {}),
        try(local.overlay[k].metrics, {}),
        { metrics_collected = local.plugins[k] },
      )
    },
  ) }

  # Log shipping lives in the overlay: an entry without one ships no logs, which
  # is a valid config, not an error. `"logs": null` drops an inherited block.
  doc = { for k, c in local.configs : k => {
    for key, v in local.merged[k] : key => v
    if v != null && !startswith(key, "//")
  } }

  # Every renamed JVM metric each config publishes. The overlay now owns the jmx
  # block, so the snake_case rename contract the JMX alarms query lives in project
  # files and can drift per project — the check block below is what makes that
  # audible instead of silently green.
  jvm_metrics = { for k, c in local.configs : k => toset(flatten([
    for e in try(local.plugins[k].jmx, []) : [
      for m in try(e.jvm.measurement, []) : try(m.rename, m.name, m)
    ]
  ])) }

  has_jmx = { for k, c in local.configs : k => length(try(local.plugins[k].jmx, [])) > 0 }

  # jsonencode of the decoded document: invalid template output fails at plan
  # time rather than landing in Parameter Store as a string the agent rejects on
  # the host. The round trip also compacts it, off the Standard-tier budget.
  config_json = { for k, doc in local.doc : k => jsonencode(doc) }
}

resource "aws_ssm_parameter" "cwagent_config" {
  for_each = local.configs

  name        = "${local.name_prefix}${each.key}"
  description = "CloudWatch Agent config for ${var.project}-${var.env} host group ${each.key} (${var.cwagent_dimension_key}=${each.value.cwagent_dimension_value})"
  type        = "String"
  tier        = var.tier
  value       = local.config_json[each.key]

  tags = merge(var.common_tags, {
    Name                  = "${local.name_prefix}${each.key}"
    Project               = var.project
    Environment           = var.env
    ManagedBy             = "terraform"
    CWAgentDimensionValue = each.value.cwagent_dimension_value
  })

  lifecycle {
    precondition {
      condition     = !local.has_jmx[each.key] || each.value.process_group != null
      error_message = "Config '${each.key}' declares a jmx plugin but no process_group. ProcessGroupName is the dimension the JMX alarms and the JVM dashboard filter on; without it their queries match nothing and sit notBreaching — green, not red."
    }

    precondition {
      condition     = var.tier != "Standard" || length(local.config_json[each.key]) <= 4096
      error_message = "Rendered agent config for '${each.key}' exceeds the 4096-byte Standard-tier limit. Set tier = \"Advanced\" (billed per parameter) or trim the overlay."
    }
  }
}

# Warning, not a blocker: an overlay may legitimately collect a subset of the JVM
# metrics, but if it drops one an alarm queries, that alarm goes quiet — and quiet
# here means notBreaching, not INSUFFICIENT_DATA. Names must match the JMX module's
# queries exactly (snake_case; see cwagent/ec2-java/README.md).
check "jvm_metrics_the_alarms_query" {
  assert {
    condition = alltrue([
      for k, present in local.has_jmx : !present || alltrue([
        for m in var.required_jvm_metrics : contains(local.jvm_metrics[k], m)
      ])
    ])
    error_message = "A jmx overlay is missing a JVM metric the alarms or dashboard query (${join(", ", var.required_jvm_metrics)}). Published: ${jsonencode(local.jvm_metrics)}"
  }
}
