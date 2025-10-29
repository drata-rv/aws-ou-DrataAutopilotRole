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
}

output "member_role_arns" {
  value       = local.member_role_arns
  description = "Map of account ID to role ARN for each member account."
}
