data "terraform_remote_state" "foundation" {
  backend = "s3"

  config = {
    bucket     = var.ops_bucket
    key        = "foundation/ops.tfstate"
    region     = var.aws_region
    role_arn   = var.ops_state_role_arn
    encrypt    = true
    use_lockfile = true
  }
}