# Versions verified at the time of writing: Terraform 1.16.2, hashicorp/google 8.5.0. RE-VERIFY before pinning
# (registry: https://registry.terraform.io/v1/providers/hashicorp/google).
terraform {
  required_version = ">= 1.16.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.5"
    }
  }

  # A backend block cannot use variables: write the bucket name here. It is created by
  # scripts/gcp-bootstrap.sh (private, versioned). The state holds no secret value.
  backend "gcs" {
    bucket = "CHANGE-ME-PROJECT_ID-tfstate"
    prefix = "infra"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Only for the budget alert: the Budgets API lives on the billing account and requires a quota
# project. Kept on its own alias so the rest of the calls do not need Service Usage enabled.
provider "google" {
  alias   = "billing"
  project = var.project_id
  region  = var.region

  user_project_override = true
  billing_project       = var.project_id
}

data "google_project" "this" {
  project_id = var.project_id
}
