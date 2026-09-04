data "aws_caller_identity" "current" {}

data "aws_organizations_organization" "org" {}

data "aws_region" "current" {}

data "aws_partition" "current" {}

# aws_organizations_organization lists accounts but not their OU/parent, so OU-based
# filtering still needs the CLI walk in scripts/discover_accounts.py.
data "external" "organization_accounts" {
  # Absolute path: some python3 builds (python.org macOS installer) don't preserve
  # cwd on relaunch, breaking relative paths.
  program = ["python3", "${abspath(path.module)}/scripts/discover_accounts.py"]

  lifecycle {
    postcondition {
      condition     = self.result.caller_account_id == data.aws_caller_identity.current.account_id
      error_message = "Account discovery ran as AWS account ${self.result.caller_account_id}, but the Terraform AWS provider is authenticated as account ${data.aws_caller_identity.current.account_id}. These must be the same AWS account - check for a mismatch between your shell's AWS CLI credentials/profile and your Terraform provider configuration (for example, a provider assume_role block that this script's AWS CLI subprocess doesn't see)."
    }

    postcondition {
      # Rejects a well-formed but nonexistent target_parent_ids entry (typo).
      condition     = length(setsubtract(toset(var.target_parent_ids), toset(try(jsondecode(self.result.discovered_parent_ids_json), [])))) == 0
      error_message = "target_parent_ids contains an ID that doesn't exist in this AWS Organization: ${join(", ", setsubtract(toset(var.target_parent_ids), toset(try(jsondecode(self.result.discovered_parent_ids_json), []))))}. Double-check the OU/root ID against AWS Organizations."
    }
  }
}

locals {
  raw_accounts = [
    for account in try(jsondecode(data.external.organization_accounts.result.accounts_json), []) : {
      id           = account["id"]
      name         = account["name"]
      arn          = account["arn"]
      parent_id    = try(account["parent_id"], null)
      ancestor_ids = try(account["ancestor_ids"], [])
    }
  ]

  management_account_id = data.aws_caller_identity.current.account_id
  organization_root_ids = [for root in data.aws_organizations_organization.org.roots : root.id]
  scoped_parent_ids     = length(var.target_parent_ids) > 0 ? var.target_parent_ids : local.organization_root_ids
  # target_parent_ids / include_account_ids / account_tag_filters each count as
  # deliberate scoping; only "organization-wide" if none of them narrow anything.
  # exclude_account_ids alone doesn't count - it only removes from an org-wide set.
  is_organization_wide = (
    length(var.target_parent_ids) == 0 &&
    length(var.include_account_ids) == 0 &&
    length(var.account_tag_filters) == 0
  )

  # Matches on any ancestor OU, not just direct parent, so target_parent_ids selects
  # accounts nested at any depth.
  parent_filtered_accounts = {
    for account in local.raw_accounts :
    account.id => account
    if length(setintersection(toset(account.ancestor_ids), toset(local.scoped_parent_ids))) > 0
  }

  include_filtered_accounts = length(var.include_account_ids) > 0 ? {
    for id, account in local.parent_filtered_accounts :
    id => account if contains(var.include_account_ids, id)
  } : local.parent_filtered_accounts

  exclude_filtered_accounts = {
    for id, account in local.include_filtered_accounts :
    id => account if !contains(var.exclude_account_ids, id)
  }
}

# Tags fetched only for the OU/include/exclude-narrowed set, and only if
# account_tag_filters is set - not for every account in the org.
data "aws_organizations_resource_tags" "account_tags" {
  for_each    = length(var.account_tag_filters) > 0 ? { for id, account in local.exclude_filtered_accounts : id => account.arn } : {}
  resource_id = each.key
}

locals {
  account_tags_map = {
    for account_id, tags_data in data.aws_organizations_resource_tags.account_tags :
    account_id => try(tags_data.tags, {})
  }

  # "" means "tag not present" below; account_tag_filters rejects "" as an allowed
  # value so it can't be used to match accounts that lack the tag.
  tag_filtered_accounts = length(var.account_tag_filters) == 0 ? local.exclude_filtered_accounts : {
    for id, account in local.exclude_filtered_accounts :
    id => account if alltrue([
      for tag_key, allowed_values in var.account_tag_filters :
      contains(allowed_values, lookup(lookup(local.account_tags_map, id, {}), tag_key, ""))
    ])
  }

  # Management account always gets its role via aws_iam_role.management below, never
  # via the StackSet path.
  member_accounts = {
    for id, account in local.tag_filtered_accounts :
    id => account if id != local.management_account_id
  }

  # Whether the management account would also match the OU/include/exclude/tag filters
  # on its own.
  management_account_matches_filters = contains(keys(local.tag_filtered_accounts), local.management_account_id)

  effective_target_region = coalesce(var.target_region, data.aws_region.current.name)

  drata_assume_role_statement = merge(
    {
      Effect = "Allow"
      Principal = {
        AWS = var.drata_aws_account_arn
      }
      Action = ["sts:AssumeRole"]
    },
    var.role_sts_externalid == null ? {} : {
      Condition = {
        StringEquals = {
          "sts:ExternalId" = var.role_sts_externalid
        }
      }
    }
  )

  role_tags_list = [
    for tag_key, tag_value in var.tags : {
      Key   = tag_key
      Value = tag_value
    }
  ]

  stack_set_name = "${var.role_name}-stackset"

  member_role_arns = {
    for account_id, _ in local.member_accounts :
    account_id => "arn:${data.aws_partition.current.partition}:iam::${account_id}:role${var.role_path}${var.role_name}"
  }

  stack_set_template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Drata Autopilot IAM role deployed across member accounts."
    Resources = {
      DrataAutopilotRole = {
        Type = "AWS::IAM::Role"
        Properties = merge({
          RoleName    = var.role_name
          Description = var.role_description
          Path        = var.role_path
          AssumeRolePolicyDocument = {
            Version   = "2012-10-17"
            Statement = [local.drata_assume_role_statement]
          }
          ManagedPolicyArns = [
            "arn:${data.aws_partition.current.partition}:iam::aws:policy/SecurityAudit"
          ]
          Policies = [
            {
              PolicyName = "DrataAdditionalPermissions"
              PolicyDocument = {
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
              }
            }
          ]
        }, length(local.role_tags_list) > 0 ? { Tags = local.role_tags_list } : {})
      }
    }
  })
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
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/SecurityAudit"
}

# Inline, not a customer-managed policy, to avoid a name collision with any
# pre-existing policy named "DrataAdditionalPermissions" in this account.
resource "aws_iam_role_policy" "management_additional_permissions" {
  count = var.include_management_account ? 1 : 0

  name = "DrataAdditionalPermissions"
  role = aws_iam_role.management[0].id

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

# Requires CloudFormation StackSets trusted access with AWS Organizations - see README.
resource "aws_cloudformation_stack_set" "member_role" {
  name             = local.stack_set_name
  permission_model = "SERVICE_MANAGED"
  capabilities     = ["CAPABILITY_NAMED_IAM"]
  call_as          = "SELF"

  # Required by AWS for permission_model = SERVICE_MANAGED. Disabled: accounts are
  # targeted explicitly via this module's own filters, not AWS's OU auto-deployment.
  auto_deployment {
    enabled = false
  }

  # Queues colliding StackSet operations instead of rejecting them; mitigates
  # OperationInProgressException (see note on the instance resource below).
  managed_execution {
    active = true
  }

  template_body = local.stack_set_template_body
  tags          = var.tags

  lifecycle {
    precondition {
      condition = contains(
        data.aws_organizations_organization.org.aws_service_access_principals,
        "member.org.stacksets.cloudformation.amazonaws.com"
      )
      error_message = "CloudFormation StackSets trusted access is not enabled for this AWS Organization. Enable it from the management account: either the CloudFormation console (StackSets -> Activate trusted access) or `aws organizations enable-aws-service-access --service-principal=member.org.stacksets.cloudformation.amazonaws.com`."
    }

    precondition {
      # call_as = "SELF" requires the actual management account, not a delegated admin.
      condition     = data.aws_caller_identity.current.account_id == data.aws_organizations_organization.org.master_account_id
      error_message = "This module must be run from the AWS Organizations management account (${data.aws_organizations_organization.org.master_account_id}), but the current Terraform AWS provider identity is account ${data.aws_caller_identity.current.account_id}. Delegated-administrator execution is not currently supported by this module."
    }

    precondition {
      condition     = !local.is_organization_wide || var.confirm_organization_wide_deployment
      error_message = "target_parent_ids is empty, which deploys the role to every account in the entire AWS Organization. If that's intentional, set confirm_organization_wide_deployment = true. Otherwise, scope this with target_parent_ids to specific OUs/roots."
    }

    precondition {
      condition     = !var.include_management_account || local.management_account_matches_filters || var.confirm_management_account_outside_filters
      error_message = "include_management_account = true creates the role in the management account (${local.management_account_id}) regardless of target_parent_ids/include_account_ids/exclude_account_ids/account_tag_filters, and this account doesn't match those filters. If that's intentional (Drata's integration needs a management-account role as a control-plane exception), set confirm_management_account_outside_filters = true."
    }

    precondition {
      condition     = length(local.member_accounts) >= var.minimum_member_account_count
      error_message = "Resolved ${length(local.member_accounts)} member account(s), below the required minimum of ${var.minimum_member_account_count} (minimum_member_account_count). Check resolved_member_account_ids - this usually means a filter didn't match what you intended."
    }

    precondition {
      condition = (
        length(var.expected_member_account_ids) == 0 ||
        length(setsubtract(toset(keys(local.member_accounts)), var.expected_member_account_ids)) == 0
        ) && (
        length(var.expected_member_account_ids) == 0 ||
        length(setsubtract(var.expected_member_account_ids, toset(keys(local.member_accounts)))) == 0
      )
      error_message = "Resolved member-account set doesn't exactly match expected_member_account_ids. Unexpected: ${join(", ", setsubtract(toset(keys(local.member_accounts)), var.expected_member_account_ids))}. Missing: ${join(", ", setsubtract(var.expected_member_account_ids, toset(keys(local.member_accounts))))}."
    }
  }
}

# One resource per account, not one pooled resource for all accounts: changing
# deployment_targets.accounts forces a full replace, so pooling would destroy and
# recreate every account's role on any single membership change. Per-account isolates
# that to just the account that changed.
# Trade-off: AWS allows only one in-flight operation per StackSet, so applying many of
# these concurrently can hit OperationInProgressException on a large first-time
# rollout - retriable, and a smaller risk than the pooled-resource blast radius.
resource "aws_cloudformation_stack_set_instance" "member" {
  for_each = local.member_accounts

  stack_set_name = aws_cloudformation_stack_set.member_role.name
  region         = local.effective_target_region

  deployment_targets {
    organizational_unit_ids = [local.organization_root_ids[0]]
    account_filter_type     = "INTERSECTION"
    accounts                = [each.key]
  }
}
