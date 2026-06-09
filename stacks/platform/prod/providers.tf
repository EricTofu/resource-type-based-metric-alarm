provider "aws" {
  region = var.aws_region

  assume_role {
    role_arn = local.tf_deployer_role_arn
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  assume_role {
    role_arn = local.tf_deployer_role_arn
  }
}
