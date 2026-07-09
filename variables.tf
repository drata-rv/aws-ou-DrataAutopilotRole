variable "drata_aws_account_arn" {
  type        = string
  default     = "arn:aws:iam::269135526815:root"
  description = "Drata's AWS account ARN"
}

variable "role_sts_externalid" {
  description = "STS ExternalId condition value to use with the role. Required: obtain this from your Drata AWS connection setup. Without it, the trust policy has no ExternalId condition at all, which is a classic cross-account confused-deputy risk given this role is deployed org-wide."
  type        = string
  default     = null

  validation {
    condition     = var.role_sts_externalid != null && length(var.role_sts_externalid) > 0
    error_message = "role_sts_externalid must be set to a non-empty value from your Drata AWS connection setup."
  }
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

  validation {
    condition     = var.role_path == "/"
    error_message = "role_path other than \"/\" is not currently supported."
  }
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
  description = "List of organization root IDs (r-xxxx) or organizational unit IDs (ou-xxxx-xxxxxxxx) to scope account selection. Matches accounts anywhere beneath the given parent(s), at any nesting depth - not just direct children. Defaults to the organization root when empty."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for id in var.target_parent_ids : can(regex("^(r-[0-9a-z]{4,32}|ou-[0-9a-z]{4,32}-[a-z0-9]{8,32})$", id))
    ])
    error_message = "Each entry in target_parent_ids must be a valid AWS Organizations root ID (r-xxxx) or organizational unit ID (ou-xxxx-xxxxxxxx)."
  }
}

variable "include_account_ids" {
  description = "Explicit allow-list of account IDs. This narrows the set already scoped by target_parent_ids/account_tag_filters down to only these accounts - it does NOT add accounts from outside that scope. When empty, all accounts meeting the other filters are included."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.include_account_ids : can(regex("^\\d{12}$", id))])
    error_message = "Each entry in include_account_ids must be a 12-digit AWS account ID string (e.g. \"123456789012\")."
  }
}

variable "exclude_account_ids" {
  description = "List of account IDs to exclude from deployment, applied after target_parent_ids/include_account_ids."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.exclude_account_ids : can(regex("^\\d{12}$", id))])
    error_message = "Each entry in exclude_account_ids must be a 12-digit AWS account ID string (e.g. \"123456789012\")."
  }
}

variable "account_tag_filters" {
  description = "Map of account tag keys to allowed values used to filter accounts (e.g., { Environment = [\"PROD\"] }). All tag conditions must match (AND)."
  type        = map(list(string))
  default     = {}

  validation {
    condition     = alltrue([for key, values in var.account_tag_filters : length(values) > 0])
    error_message = "Each key in account_tag_filters must map to a non-empty list of allowed values - an empty list would silently match zero accounts."
  }
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
