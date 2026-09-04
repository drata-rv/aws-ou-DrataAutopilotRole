locals {
  management_role_arn_output = var.include_management_account ? aws_iam_role.management[0].arn : null
}

output "management_role_arn" {
  value       = local.management_role_arn_output
  description = "ARN of the role created in the management account (if enabled)."
}

output "drata_role_arn" {
  value       = local.management_role_arn_output
  description = "Single ARN to provide to Drata for the AWS OU integration."

  precondition {
    # Drata's AWS OU connection needs a non-null management-account role ARN here.
    condition     = var.include_management_account
    error_message = "drata_role_arn requires include_management_account = true - Drata's AWS OU integration is configured with a single management-account role ARN. Set include_management_account = true, or use member_role_arns directly if this deployment intentionally excludes the management account."
  }
}

output "member_role_arns" {
  value       = local.member_role_arns
  description = "Map of account ID to role ARN for each member account. Constructed deterministically from the account ID, role_path, and role_name (all of which are validated/fixed inputs) - not read back from the deployed StackSet instances."
}

output "resolved_member_account_ids" {
  value       = sort(keys(local.member_accounts))
  description = "Account IDs that will receive the StackSet-deployed role, after OU/include/exclude/tag filtering. Review this on every plan - especially with target_parent_ids left empty (organization-wide scope)."
}

output "resolved_member_account_count" {
  value       = length(local.member_accounts)
  description = "Count of resolved_member_account_ids. A 0 here with member accounts expected usually means an OU/tag/include filter didn't match what you intended - it does not error by itself, since 0 member accounts is a valid configuration when include_management_account = true and no member accounts are wanted."
}

output "all_role_account_ids" {
  value       = sort(concat(keys(local.member_accounts), var.include_management_account ? [local.management_account_id] : []))
  description = "Every account that receives the role, including the management account when include_management_account = true. Use this (not resolved_member_account_ids alone) to review the complete deployment footprint."
}
