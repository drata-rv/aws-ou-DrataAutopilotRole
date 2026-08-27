data "aws_caller_identity" "current" {}

data "aws_organizations_organization" "org" {}

data "aws_region" "current" {}

data "aws_partition" "current" {}

# External helper walks the AWS Organizations OU tree (via the AWS CLI) because the AWS
# provider no longer exposes a dedicated data source for this. See scripts/discover_accounts.py
# for the full discovery logic (OU-tree walk, active-account filtering, retry/backoff).
data "external" "organization_accounts" {
  # Absolute path, not "${path.module}/..." - some python3 builds (e.g. the
  # python.org macOS installer) re-exec themselves through a launcher that
  # doesn't reliably preserve cwd, breaking relative-path resolution.
  program = ["python3", "${abspath(path.module)}/scripts/discover_accounts.py"]

  lifecycle {
    postcondition {
      condition     = self.result.caller_account_id == data.aws_caller_identity.current.account_id
      error_message = "Account discovery ran as AWS account ${self.result.caller_account_id}, but the Terraform AWS provider is authenticated as account ${data.aws_caller_identity.current.account_id}. These must be the same identity - check for a mismatch between your shell's AWS CLI credentials/profile and your Terraform provider configuration (for example, a provider assume_role block that this script's AWS CLI subprocess doesn't see)."
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
  # An explicit include_account_ids allow-list is just as deliberate a scope as
  # target_parent_ids - only treat this as "organization-wide" if NEITHER is set.
  is_organization_wide = length(var.target_parent_ids) == 0 && length(var.include_account_ids) == 0

  # An account matches if ANY OU in its ancestor chain (immediate parent up through
  # the organization root) is in scope - so target_parent_ids selects accounts nested
  # at any depth beneath the given OU(s), not just its direct children.
  #
  # Tags are deliberately NOT fetched yet at this point - only once the candidate set
  # is narrowed down by OU/include/exclude, and only if tag filtering is actually used
  # (see account_tags_map below). Fetching tags for every account in the org regardless
  # of scope means paying for organizations:ListTagsForResource on accounts nobody
  # asked about, and one throttled/denied read anywhere in the whole org can fail the
  # entire plan even when tag filtering is off.
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

# Only created when tag filtering is actually configured, and only for the set of
# accounts that already passed OU/include/exclude filtering - not the whole org.
data "aws_organizations_resource_tags" "account_tags" {
  for_each    = length(var.account_tag_filters) > 0 ? { for id, account in local.exclude_filtered_accounts : id => account.arn } : {}
  resource_id = each.key
}

locals {
  account_tags_map = {
    for account_id, tags_data in data.aws_organizations_resource_tags.account_tags :
    account_id => try(tags_data.tags, {})
  }

  # "" is reserved as the "tag not present" sentinel below, so a tag genuinely set to
  # an empty string is treated the same as an absent tag - account_tag_filters rejects
  # empty-string allowed values (see variables.tf) specifically so this can't be used
  # to accidentally match accounts that don't actually have the tag.
  tag_filtered_accounts = length(var.account_tag_filters) == 0 ? local.exclude_filtered_accounts : {
    for id, account in local.exclude_filtered_accounts :
    id => account if alltrue([
      for tag_key, allowed_values in var.account_tag_filters :
      contains(allowed_values, lookup(lookup(local.account_tags_map, id, {}), tag_key, ""))
    ])
  }

  # The management account never receives its role via the StackSet path - it's
  # provisioned separately below (aws_iam_role.management), gated by the same
  # var.include_management_account - so it's always excluded here regardless.
  member_accounts = {
    for id, account in local.tag_filtered_accounts :
    id => account if id != local.management_account_id
  }

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

# Inline (not a separate customer-managed policy) to match the StackSet template's
# member-account policy model, and to avoid a name collision with any pre-existing
# customer-managed policy named "DrataAdditionalPermissions" in this account.
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

# StackSet rolls the IAM role out to every selected member account. Requires trusted
# access for CloudFormation StackSets (AWS Organizations) - see README prerequisites.
resource "aws_cloudformation_stack_set" "member_role" {
  name             = local.stack_set_name
  permission_model = "SERVICE_MANAGED"
  capabilities     = ["CAPABILITY_NAMED_IAM"]
  call_as          = "SELF"

  # Required by AWS whenever permission_model = SERVICE_MANAGED (CreateStackSet
  # rejects the request otherwise: "AutoDeployment is required"). Disabled because
  # this module targets accounts explicitly via its own include/exclude/tag filters
  # and the StackSet instance resource below - enabling AWS's native auto-deployment
  # would let it silently expand the role to every account in a target OU, bypassing
  # that scoping entirely.
  auto_deployment {
    enabled = false
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
      # call_as = "SELF" above assumes Terraform is running as the org's actual
      # management account (not a delegated administrator, which would need
      # call_as = "DELEGATED_ADMIN" instead).
      condition     = data.aws_caller_identity.current.account_id == data.aws_organizations_organization.org.master_account_id
      error_message = "This module must be run from the AWS Organizations management account (${data.aws_organizations_organization.org.master_account_id}), but the current Terraform AWS provider identity is account ${data.aws_caller_identity.current.account_id}. Delegated-administrator execution is not currently supported by this module."
    }

    precondition {
      # An empty target_parent_ids deploys to every account in the entire
      # organization by design (see scoped_parent_ids) - require an explicit,
      # deliberate opt-in rather than let that happen because a caller only set
      # the required role_sts_externalid and nothing else.
      condition     = !local.is_organization_wide || var.confirm_organization_wide_deployment
      error_message = "target_parent_ids is empty, which deploys the role to every account in the entire AWS Organization. If that's intentional, set confirm_organization_wide_deployment = true. Otherwise, scope this with target_parent_ids to specific OUs/roots."
    }
  }
}

# A single StackSet instance resource targeting every selected member account at once,
# rather than one resource per account. AWS generally serializes operations against a
# single StackSet, so many per-account resources with Terraform's default parallelism
# can collide with "OperationInProgressException" at scale; one resource means one
# StackSet operation, using AWS's own concurrency controls (operation_preferences)
# instead of Terraform's.
resource "aws_cloudformation_stack_set_instance" "members" {
  count = length(local.member_accounts) > 0 ? 1 : 0

  stack_set_name = aws_cloudformation_stack_set.member_role.name
  region         = local.effective_target_region

  deployment_targets {
    organizational_unit_ids = [local.organization_root_ids[0]]
    account_filter_type     = "INTERSECTION"
    accounts                = keys(local.member_accounts)
  }

  operation_preferences {
    max_concurrent_percentage    = 100
    failure_tolerance_percentage = 10
    concurrency_mode             = "SOFT_FAILURE_TOLERANCE"
  }
}
