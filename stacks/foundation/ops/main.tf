locals {
  state_bucket_name = "${var.org}-tfstate"
}

# S3 bucket for Terraform state
resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket_name

  tags = merge(var.common_tags, {
    Name       = local.state_bucket_name
    ManagedBy  = "Terraform"
    Purpose    = "Terraform state storage"
  })
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.tfstate.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# KMS CMK for state encryption
resource "aws_kms_key" "tfstate" {
  description             = "Terraform state encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(var.common_tags, {
    Name       = "tfstate-key"
    ManagedBy  = "Terraform"
    Purpose    = "Terraform state encryption"
  })
}

resource "aws_kms_alias" "tfstate" {
  name          = "alias/tfstate"
  target_key_id = aws_kms_key.tfstate.key_id
}

# IAM role for cross-account state access
resource "aws_iam_role" "tf_state_access" {
  name = "tf-state-access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = var.caller_principal_arn
        }
        Action = "sts:AssumeRole"
        Sid    = "AllowCallerPrincipal"
      },
      {
        Effect = "Allow"
        Principal = {
          AWS = [
            for alias, acct in var.accounts : acct.tf_deployer_role_arn
          ]
        }
        Action = "sts:AssumeRole"
        Sid    = "AllowTargetAccountDeployers"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = var.org
          }
        }
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name       = "tf-state-access"
    ManagedBy  = "Terraform"
    Purpose    = "Cross-account Terraform state access"
  })
}

resource "aws_iam_role_policy" "tf_state_access" {
  name = "tf-state-access-policy"
  role = aws_iam_role.tf_state_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          aws_s3_bucket.tfstate.arn,
          "${aws_s3_bucket.tfstate.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext"
        ]
        Resource = aws_kms_key.tfstate.arn
      }
    ]
  })
}