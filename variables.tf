variable "drata_aws_account_arn" {
  type        = string
  default     = "arn:aws:iam::269135526815:root"
  description = "Drata's AWS account ARN"

  validation {
    condition     = can(regex("^arn:(aws|aws-cn|aws-us-gov|aws-iso|aws-iso-b):iam::\\d{12}:root$", var.drata_aws_account_arn))
    error_message = "drata_aws_account_arn must be an account root ARN of the form arn:<partition>:iam::<12-digit-account-id>:root, with <partition> one of aws, aws-cn, aws-us-gov, aws-iso, aws-iso-b."
  }
}

variable "role_sts_externalid" {
  description = "STS ExternalId condition value to use with the role. Required: obtain this from your Drata AWS connection setup. Without it, the trust policy has no ExternalId condition at all, which is a classic cross-account confused-deputy risk given this role is deployed org-wide."
  type        = string
  nullable    = false
  sensitive   = true

  validation {
    condition     = length(trimspace(var.role_sts_externalid)) > 0
    error_message = "role_sts_externalid must be set to a non-empty value from your Drata AWS connection setup."
  }
}

variable "role_name" {
  description = "IAM role name"
  type        = string
  default     = "DrataAutopilotRole"

  validation {
    # IAM RoleName's real max is 64 chars (not CloudFormation StackSetName's 128) -
    # role_name IS the RoleName directly, and even with the "-stackset" suffix added
    # for the StackSet name, 64+9=73 stays well under CloudFormation's 128 limit. A
    # longer-but-under-128 name previously passed this validation and only failed
    # deep inside `apply` at the real IAM CreateRole call.
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{0,63}$", var.role_name))
    error_message = "role_name must start with a letter, contain only letters/digits/hyphens, and be at most 64 characters (IAM's RoleName limit)."
  }
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

  validation {
    condition     = length(var.include_account_ids) == length(distinct(var.include_account_ids))
    error_message = "include_account_ids contains duplicate account IDs."
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

  validation {
    condition     = length(var.exclude_account_ids) == length(distinct(var.exclude_account_ids))
    error_message = "exclude_account_ids contains duplicate account IDs."
  }

  validation {
    condition     = length(setintersection(toset(var.include_account_ids), toset(var.exclude_account_ids))) == 0
    error_message = "An account ID cannot appear in both include_account_ids and exclude_account_ids."
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

  validation {
    condition     = alltrue([for key, values in var.account_tag_filters : !contains(values, "")])
    error_message = "account_tag_filters values cannot include an empty string - an empty string is reserved internally to mean \"this account doesn't have the tag\", so allowing it as a match value would let accounts without the tag match unintentionally."
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

variable "confirm_organization_wide_deployment" {
  description = "Required explicit opt-in when target_parent_ids is left empty, since that deploys the role to every account in the entire AWS Organization. Has no effect when target_parent_ids is set."
  type        = bool
  default     = false
}
