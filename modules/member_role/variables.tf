variable "account_id" {
  description = "AWS account ID where the role will be created"
  type        = string
}

variable "organization_access_role_name" {
  description = "Name of the intermediary role used to assume into the target account"
  type        = string
}

variable "target_assume_role_external_id" {
  description = "Optional external ID used when assuming into the target account"
  type        = string
  default     = null
}

variable "assume_role_session_name" {
  description = "Session name used while assuming into the target account"
  type        = string
}

variable "target_region" {
  description = "AWS region used for the target account provider"
  type        = string
}

variable "drata_aws_account_arn" {
  description = "Drata's AWS account ARN"
  type        = string
}

variable "role_sts_externalid" {
  description = "STS ExternalId condition value to use with the role"
  type        = string
  default     = null
}

variable "role_name" {
  description = "IAM role name"
  type        = string
}

variable "role_path" {
  description = "Path of IAM role"
  type        = string
}

variable "role_description" {
  description = "IAM Role description"
  type        = string
}

variable "tags" {
  description = "A map of tags to add to IAM role resources"
  type        = map(string)
  default     = {}
}
