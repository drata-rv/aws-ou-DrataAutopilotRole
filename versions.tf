terraform {
  # >= 1.9.0, not 1.3.0: exclude_account_ids' overlap-with-include_account_ids
  # validation cross-references a sibling variable, which Terraform rejects
  # outright (a hard init/validate failure, not just a skipped check) before 1.9.
  required_version = ">= 1.9.0"

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
