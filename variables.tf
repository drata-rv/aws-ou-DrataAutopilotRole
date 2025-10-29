variable "drata_aws_account_arn" {
  type        = string
  default     = "arn:aws:iam::269135526815:root"
  description = "Drata's AWS account ARN"
}

variable "role_sts_externalid" {
  description = "STS ExternalId condition value to use with the role"
  type        = string
  default     = null
}

variable "role_name" {
  description = "IAM role name"
  type        = string
  default     = "DrataAutopilotRole"
}

variable "role_path" {
  description = "Path of IAM role (we currently do not support a path other than '/')"
  type        = string
  default     = "/"
}

variable "role_description" {
  description = "IAM Role description"
  type        = string
  default     = "Cross-account read-only access for Drata Autopilot"
}

variable "tags" {
  description = "A map of tags to add to IAM role resources"
  type        = map(string)
  default     = {}
}

variable "target_parent_ids" {
  description = "List of organizational unit IDs to scope account selection. Defaults to the organization root when empty."
  type        = list(string)
  default     = []
}

variable "include_account_ids" {
  description = "Explicit list of account IDs to include. When empty, all accounts meeting other filters are included."
  type        = list(string)
  default     = []
}

variable "exclude_account_ids" {
  description = "List of account IDs to exclude from deployment."
  type        = list(string)
  default     = []
}

variable "account_tag_filters" {
  description = "Map of account tag keys to allowed values used to filter accounts (e.g., { Environment = [\"PROD\"] })."
  type        = map(list(string))
  default     = {}
}

variable "include_management_account" {
  description = "Whether to create the IAM role in the management account executing Terraform."
  type        = bool
  default     = true
}

variable "target_region" {
  description = "AWS region to target when creating resources in member accounts."
  type        = string
  default     = null
}
