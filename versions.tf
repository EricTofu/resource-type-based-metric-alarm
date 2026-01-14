terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Provider for global resources (CloudFront, WAF Global, Route53, etc.)
# CloudFront metrics are only available in us-east-1
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
