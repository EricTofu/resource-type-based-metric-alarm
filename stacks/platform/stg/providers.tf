provider "aws" {
  region = var.aws_region

  assume_role {
    role_arn = data.terraform_remote_state.foundation.outputs.accounts[var.alias].tf_deployer_role_arn
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  assume_role {
    role_arn = data.terraform_remote_state.foundation.outputs.accounts[var.alias].tf_deployer_role_arn
  }
}