data "terraform_remote_state" "platform" {
  backend = "s3"

  config = {
    bucket       = var.ops_bucket
    key          = "account-${var.alias}/platform/sns.tfstate"
    region       = var.aws_region
    role_arn     = var.ops_state_role_arn
    encrypt      = true
    use_lockfile = true
  }
}

locals {
  project               = var.service
  sns_topic_arns        = data.terraform_remote_state.platform.outputs.sns_topic_arns
  sns_topic_arns_global = data.terraform_remote_state.platform.outputs.sns_topic_arns_global
}
