data "aws_caller_identity" "current" {}

data "aws_organizations_organization" "org" {}

data "aws_region" "current" {}

# External helper pulls organization accounts (with parent OU IDs) using the AWS CLI
# because the AWS provider no longer exposes a dedicated data source for this.
data "external" "organization_accounts" {
  program = [
    "bash",
    "-lc",
    <<-SCRIPT
set -euo pipefail
python3 - <<'PY'
import json
import subprocess
import sys

def aws_json(args):
    cmd = ["aws"] + args + ["--output", "json"]
    try:
        proc = subprocess.run(cmd, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as exc:
        sys.stderr.write(exc.stderr or "")
        sys.exit(exc.returncode)
    return json.loads(proc.stdout or "{}")

accounts_data = aws_json(["organizations", "list-accounts"])
accounts = accounts_data.get("Accounts", [])
results = []
for account in accounts:
    parents = aws_json(["organizations", "list-parents", "--child-id", account.get("Id", "")])
    parent_entries = parents.get("Parents", [])
    parent_id = parent_entries[0].get("Id") if parent_entries else None
    results.append(
        {
            "id": account.get("Id"),
            "name": account.get("Name"),
            "arn": account.get("Arn"),
            "parent_id": parent_id,
        }
    )

# Flatten for Terraform external data source
flat_output = {}
for i, account in enumerate(results):
    flat_output[f"id_{i}"] = account.get("id", "")
    flat_output[f"name_{i}"] = account.get("name", "")
    flat_output[f"arn_{i}"] = account.get("arn", "")
    flat_output[f"parent_id_{i}"] = account.get("parent_id", "")

print(json.dumps(flat_output))
PY
SCRIPT
  ]
}

locals {
  raw_accounts = [
    for account in try(data.external.organization_accounts.result.accounts, []) : {
      id        = account["id"]
      name      = account["name"]
      arn       = account["arn"]
      parent_id = try(account["parent_id"], null)
    }
  ]
}

data "aws_organizations_resource_tags" "account_tags" {
  for_each    = { for account in local.raw_accounts : account.id => account.arn }
  resource_id = each.value
}

locals {
  management_account_id = data.aws_caller_identity.current.account_id
  organization_root_ids = [for root in data.aws_organizations_organization.org.roots : root.id]
  scoped_parent_ids     = length(var.target_parent_ids) > 0 ? var.target_parent_ids : local.organization_root_ids

  account_tags_map = {
    for account_id, tags_data in data.aws_organizations_resource_tags.account_tags :
    account_id => try(tags_data.tags, {})
  }

  discovered_accounts = {
    for account in local.raw_accounts :
    account.id => {
      id        = account.id
      name      = account.name
      arn       = account.arn
      parent_id = account.parent_id
      tags      = lookup(local.account_tags_map, account.id, {})
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

  effective_target_region = coalesce(var.target_region, data.aws_region.current.id)

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
    account_id => "arn:aws:iam::${account_id}:role/${var.role_name}"
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
            "arn:aws:iam::aws:policy/SecurityAudit"
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

# StackSet rolls the IAM role out to every selected member account. Requires trusted
# access for CloudFormation StackSets (AWS Organizations).
resource "aws_cloudformation_stack_set" "member_role" {
  name             = local.stack_set_name
  permission_model = "SERVICE_MANAGED"
  capabilities     = ["CAPABILITY_NAMED_IAM"]
  call_as          = "SELF"

  template_body = local.stack_set_template_body
  tags          = var.tags

  auto_deployment {
    enabled                        = true
    retain_stacks_on_account_removal = false
  }
}

resource "aws_cloudformation_stack_set_instance" "member" {
  for_each = local.member_accounts

  stack_set_name = aws_cloudformation_stack_set.member_role.name
  region         = local.effective_target_region

  deployment_targets {
    accounts = [each.key]
  }
}
