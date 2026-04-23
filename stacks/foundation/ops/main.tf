#-----------------------------------------------------------------------------
# KMS CMK for state bucket SSE.
#-----------------------------------------------------------------------------
resource "aws_kms_key" "tfstate" {
  description             = "CMK for Terraform state encryption (Ops bucket)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = merge(var.common_tags, { Purpose = "tfstate-sse" })
}

resource "aws_kms_alias" "tfstate" {
  name          = "alias/tfstate"
  target_key_id = aws_kms_key.tfstate.key_id
}

#-----------------------------------------------------------------------------
# Single S3 bucket for all Terraform state, Org-wide.
#-----------------------------------------------------------------------------
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.common_tags["Org"]}-tfstate"
  tags   = merge(var.common_tags, { Purpose = "tfstate" })
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
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tfstate.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

#-----------------------------------------------------------------------------
# Cross-account tf-state-access role.
# Assumed by every leaf's backend "s3" { role_arn = ... }.
#-----------------------------------------------------------------------------
data "aws_iam_policy_document" "tf_state_access_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [var.caller_principal_arn]
    }
  }

  dynamic "statement" {
    for_each = var.accounts
    content {
      effect  = "Allow"
      actions = ["sts:AssumeRole"]
      principals {
        type        = "AWS"
        identifiers = [statement.value.tf_deployer_role_arn]
      }
    }
  }
}

resource "aws_iam_role" "tf_state_access" {
  name               = "tf-state-access"
  assume_role_policy = data.aws_iam_policy_document.tf_state_access_trust.json
  tags               = var.common_tags
}

data "aws_iam_policy_document" "tf_state_access" {
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tfstate.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.tfstate.arn}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [aws_kms_key.tfstate.arn]
  }
}

resource "aws_iam_role_policy" "tf_state_access" {
  name   = "tf-state-access"
  role   = aws_iam_role.tf_state_access.id
  policy = data.aws_iam_policy_document.tf_state_access.json
}
