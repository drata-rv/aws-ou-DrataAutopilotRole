terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_organizations_organization" "org" {}

data "aws_organizations_accounts" "all" {}

data "aws_region" "current" {}

data "aws_organizations_resource_tags" "account_tags" {
  for_each    = { for account in data.aws_organizations_accounts.all.accounts : account.id => account.arn }
  resource_id = each.value
}

locals {
  management_account_id = data.aws_caller_identity.current.account_id
  organization_root_ids = [for root in data.aws_organizations_organization.org.roots : root.id]
  scoped_parent_ids     = length(var.target_parent_ids) > 0 ? var.target_parent_ids : local.organization_root_ids

  discovered_accounts = {
    for account in data.aws_organizations_accounts.all.accounts :
    account.id => {
      id        = account.id
      name      = account.name
      arn       = account.arn
      parent_id = try(account.parent_id, null)
      tags      = try(data.aws_organizations_resource_tags.account_tags[account.id].tags, {})
    }
  }

  parent_filtered_accounts = {
    for id, account in local.discovered_accounts :
    id => account
    if(
      account.parent_id != null && length(local.scoped_parent_ids) > 0 ?
      contains(local.scoped_parent_ids, account.parent_id) :
      contains(local.scoped_parent_ids, local.organization_root_ids[0])
    )
  }

  include_filtered_accounts = length(var.include_account_ids) > 0 ? {
    for id, account in local.parent_filtered_accounts :
    id => account if contains(var.include_account_ids, id)
  } : local.parent_filtered_accounts

  exclude_filtered_accounts = {
    for id, account in local.include_filtered_accounts :
    id => account if !contains(var.exclude_account_ids, id)
  }

  tag_filtered_accounts = length(var.account_tag_filters) == 0 ? local.exclude_filtered_accounts : {
    for id, account in local.exclude_filtered_accounts :
    id => account if alltrue([
      for tag_key, allowed_values in var.account_tag_filters :
      contains(allowed_values, lookup(account.tags, tag_key, ""))
    ])
  }

  management_account_metadata = lookup(local.discovered_accounts, local.management_account_id, {
    id        = local.management_account_id
    name      = "management"
    arn       = "arn:aws:iam::${local.management_account_id}:root"
    parent_id = local.organization_root_ids[0]
    tags      = {}
  })

  selected_accounts = var.include_management_account ? merge(
    local.tag_filtered_accounts,
    {
      (local.management_account_id) = local.management_account_metadata
    }
  ) : local.tag_filtered_accounts

  member_accounts = {
    for id, account in local.selected_accounts :
    id => account if id != local.management_account_id
  }

  effective_target_region = coalesce(var.target_region, data.aws_region.current.name)
}

data "aws_iam_policy_document" "drata_autopilot_assume_role" {
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

resource "aws_iam_policy" "drata_additional_permissions" {
  count = var.include_management_account ? 1 : 0

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

resource "aws_iam_role" "management" {
  count = var.include_management_account ? 1 : 0

  name        = var.role_name
  path        = var.role_path
  description = var.role_description

  assume_role_policy = data.aws_iam_policy_document.drata_autopilot_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "management_security_audit" {
  count = var.include_management_account ? 1 : 0

  role       = aws_iam_role.management[0].name
  policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

resource "aws_iam_role_policy_attachment" "management_additional_permissions" {
  count = var.include_management_account ? 1 : 0

  role       = aws_iam_role.management[0].name
  policy_arn = aws_iam_policy.drata_additional_permissions[0].arn
}

module "member_roles" {
  for_each = local.member_accounts
  source   = "./modules/member_role"

  account_id                     = each.value.id
  organization_access_role_name  = var.organization_access_role_name
  target_assume_role_external_id = var.target_assume_role_external_id
  assume_role_session_name       = var.assume_role_session_name
  target_region                  = local.effective_target_region
  drata_aws_account_arn          = var.drata_aws_account_arn
  role_sts_externalid            = var.role_sts_externalid
  role_name                      = var.role_name
  role_path                      = var.role_path
  role_description               = var.role_description
  tags                           = var.tags
}
