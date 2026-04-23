data "terraform_remote_state" "foundation" {
  backend = "s3"
  config = {
    bucket   = var.ops_state_bucket
    key      = "foundation/ops.tfstate"
    region   = var.aws_region
    role_arn = var.ops_state_role_arn
    encrypt  = true
  }
}

locals {
  target_account       = data.terraform_remote_state.foundation.outputs.accounts[var.alias]
  tf_deployer_role_arn = local.target_account.tf_deployer_role_arn
}
