data "aws_caller_identity" "current" {}

data "aws_organizations_organization" "org" {}

data "aws_region" "current" {}

# External helper walks the AWS Organizations OU tree (via the AWS CLI) because the AWS
# provider no longer exposes a dedicated data source for this. Walking top-down via
# list-organizational-units-for-parent / list-accounts-for-parent (rather than calling
# list-parents once per account) keeps API call volume proportional to the number of OUs
# rather than the number of accounts, and yields each account's full ancestor OU chain so
# target_parent_ids can match accounts nested at any depth, not just direct children.
data "external" "organization_accounts" {
  program = [
    "bash",
    "-c",
    <<-SCRIPT
set -euo pipefail
python3 - <<'PY'
import json
import os
import random
import subprocess
import sys
import time

# Defense in depth: lean on the CLI/SDK's own adaptive retry in addition to our
# explicit backoff below, in case throttling happens deeper inside a single call
# (e.g. mid-pagination) than our retry loop can see.
os.environ.setdefault("AWS_RETRY_MODE", "adaptive")
os.environ.setdefault("AWS_MAX_ATTEMPTS", "10")


def aws_json(args, max_attempts=8):
    cmd = ["aws"] + args + ["--output", "json"]
    for attempt in range(1, max_attempts + 1):
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode == 0:
            return json.loads(proc.stdout or "{}")
        stderr = proc.stderr or ""
        throttled = any(
            marker in stderr
            for marker in ("Throttling", "TooManyRequestsException", "RequestLimitExceeded")
        )
        if throttled and attempt < max_attempts:
            time.sleep(min(2 ** attempt, 30) + random.uniform(0, 1))
            continue
        sys.stderr.write(stderr)
        sys.exit(proc.returncode or 1)
    return {}


ou_parent = {}
accounts = []


def walk(parent_id):
    for account in aws_json(["organizations", "list-accounts-for-parent", "--parent-id", parent_id]).get("Accounts", []):
        accounts.append(
            {
                "id": account.get("Id"),
                "name": account.get("Name"),
                "arn": account.get("Arn"),
                "parent_id": parent_id,
            }
        )
    for ou in aws_json(["organizations", "list-organizational-units-for-parent", "--parent-id", parent_id]).get("OrganizationalUnits", []):
        ou_id = ou.get("Id")
        ou_parent[ou_id] = parent_id
        walk(ou_id)


def ancestor_chain(parent_id):
    chain = [parent_id]
    current = parent_id
    while current in ou_parent:
        current = ou_parent[current]
        chain.append(current)
    return chain


for root in aws_json(["organizations", "list-roots"]).get("Roots", []):
    walk(root.get("Id"))

for account in accounts:
    account["ancestor_ids"] = ancestor_chain(account["parent_id"])

print(json.dumps({"accounts_json": json.dumps(accounts)}))
PY
SCRIPT
  ]
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
}

data "aws_organizations_resource_tags" "account_tags" {
  for_each    = { for account in local.raw_accounts : account.id => account.arn }
  resource_id = each.key
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
      id           = account.id
      name         = account.name
      arn          = account.arn
      parent_id    = account.parent_id
      ancestor_ids = account.ancestor_ids
      tags         = lookup(local.account_tags_map, account.id, {})
    }
  }

  # An account matches if ANY OU in its ancestor chain (immediate parent up through
  # the organization root) is in scope - so target_parent_ids selects accounts nested
  # at any depth beneath the given OU(s), not just its direct children.
  parent_filtered_accounts = {
    for id, account in local.discovered_accounts :
    id => account
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

  tag_filtered_accounts = length(var.account_tag_filters) == 0 ? local.exclude_filtered_accounts : {
    for id, account in local.exclude_filtered_accounts :
    id => account if alltrue([
      for tag_key, allowed_values in var.account_tag_filters :
      contains(allowed_values, lookup(account.tags, tag_key, ""))
    ])
  }

  # The management account never receives its role via the StackSet path - it's
  # provisioned separately below (aws_iam_role.management), gated by the same
  # var.include_management_account - so it's always excluded here regardless.
  member_accounts = {
    for id, account in local.tag_filtered_accounts :
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
    account_id => "arn:aws:iam::${account_id}:role${var.role_path}${var.role_name}"
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

  # Required by AWS whenever permission_model = SERVICE_MANAGED (CreateStackSet
  # rejects the request otherwise: "AutoDeployment is required"). Disabled because
  # this module targets accounts explicitly via its own include/exclude/tag filters
  # and per-account aws_cloudformation_stack_set_instance resources below - enabling
  # AWS's native auto-deployment would let it silently expand the role to every
  # account in a target OU, bypassing that scoping entirely.
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
      error_message = "CloudFormation StackSets trusted access is not enabled for this AWS Organization. Enable it first (from the management account): aws organizations enable-aws-service-access --service-principal=member.org.stacksets.cloudformation.amazonaws.com"
    }
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
