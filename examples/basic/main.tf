terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 6.0"
    }
    external = {
      source  = "hashicorp/external"
      version = ">= 2.3, < 3.0"
    }
  }
}

provider "aws" {
  region = "us-east-1" # pick any region; IAM itself is global
  # Must resolve to the SAME AWS identity as the AWS CLI in this environment -
  # the module verifies this at plan time and fails clearly if they diverge.
}

variable "role_sts_externalid" {
  type        = string
  sensitive   = true
  description = "External ID from Drata -> Account Settings -> Connections -> AWS."
}

variable "target_parent_ids" {
  type        = list(string)
  default     = []
  description = "OU/root IDs to scope this deployment to. Leave empty only if you want every account in the org (see confirm_organization_wide_deployment)."
}

module "drata_autopilot_role" {
  source = "../.."

  drata_aws_account_arn = "arn:aws:iam::269135526815:root"
  role_sts_externalid   = var.role_sts_externalid

  target_parent_ids = var.target_parent_ids
  # confirm_organization_wide_deployment = true  # only if target_parent_ids is intentionally empty

  include_management_account = true
}

output "drata_role_arn" {
  value       = module.drata_autopilot_role.drata_role_arn
  description = "Single ARN to paste into Drata's AWS OU connection."
}

output "resolved_member_account_ids" {
  value       = module.drata_autopilot_role.resolved_member_account_ids
  description = "Review this list before applying - it's the actual account set that will receive the role."
}
