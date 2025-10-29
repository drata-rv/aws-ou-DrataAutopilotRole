terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  alias  = "target"
  region = var.target_region

  assume_role {
    role_arn     = "arn:aws:iam::${var.account_id}:role/${var.organization_access_role_name}"
    session_name = var.assume_role_session_name
    external_id  = var.target_assume_role_external_id
  }
}

data "aws_iam_policy_document" "drata_autopilot_assume_role" {
  provider = aws.target

  statement {
    effect = "Allow"

    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [var.drata_aws_account_arn]
    }

    dynamic "condition" {
      for_each = var.role_sts_externalid != null ? [true] : []
      content {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [var.role_sts_externalid]
      }
    }
  }
}

resource "aws_iam_role" "drata" {
  provider = aws.target

  name        = var.role_name
  path        = var.role_path
  description = var.role_description

  assume_role_policy = data.aws_iam_policy_document.drata_autopilot_assume_role.json

  tags = var.tags
}

resource "aws_iam_policy" "drata_additional_permissions" {
  provider = aws.target

  name        = "DrataAdditionalPermissions"
  description = "Custom policy for permissions in addition to the SecurityAudit policy"
  path        = "/"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "backup:ListBackupJobs",
          "backup:ListRecoveryPointsByResource"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "security_audit" {
  provider = aws.target

  role       = aws_iam_role.drata.name
  policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

resource "aws_iam_role_policy_attachment" "drata_additional_permissions" {
  provider = aws.target

  role       = aws_iam_role.drata.name
  policy_arn = aws_iam_policy.drata_additional_permissions.arn
}

output "role_arn" {
  value       = aws_iam_role.drata.arn
  description = "The ARN of the role created in the target account"
}
