# Loads (or rotates) the VALUE of one secret in Secret Manager. Separate root module on purpose:
#
#   terraform -chdir=infra/secrets init     # once
#   terraform -chdir=infra/secrets apply    # asks which secret and its value (not echoed)
#
# Terraform cannot ask "only if missing": it prompts for every variable without a value, every run.
# So values live here and the main infra/ asks for nothing; there, a mounted secret without a value
# fails the plan naming it.
#
# The value is never stored outside Secret Manager: the variable is ephemeral and the attribute is
# write-only, so it is in neither the plan nor the state. Each apply adds a new version; old ones stay
# in Secret Manager (Terraform lets go of them, it does not delete them). New instances pick the new
# value up by themselves (Cloud Run resolves `latest` when an instance starts).
#
# Local state (gitignored): it holds no secret value.

terraform {
  required_version = ">= 1.16.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.5"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

provider "google" {
  project = var.project_id
}

variable "project_id" {
  description = "GCP project ID."
  type        = string
  default     = "CHANGE-ME"
}

locals {
  # Adapt to the app. Generated = Enter on an empty value makes one. External = must be pasted.
  generated = ["api-key", "jwt-secret"]
  external  = ["db-uri", "webhook-secret"]
  # Generated secrets that must be a Fernet key (32 url-safe base64 bytes) instead of a long string.
  fernet_keys = []
  # Values that must look a certain way (prefix check). db-uri: "mongodb" (MongoDB/Atlas) or
  # "postgres" (Postgres by URL; covers postgres:// and postgresql://). Drop it with the Cloud SQL connector.
  must_start_with = { "db-uri" = "mongodb" }
}

variable "secret" {
  description = "Which secret. Rotating one that already has a value can log everybody out (jwt-secret) or break services until they restart (api-key)."
  type        = string

  validation {
    condition     = contains(concat(local.generated, local.external), var.secret)
    error_message = "Not a secret of this app. See `generated` and `external` in secrets/main.tf."
  }
}

variable "value" {
  description = "The value (not shown while pasting). Empty = generate a random one (generated secrets only)."
  type        = string
  sensitive   = true
  ephemeral   = true
}

# Ephemeral generators: the value exists only during the apply.
ephemeral "random_password" "long" {
  length  = 64
  special = false
}

# Fernet key: 32 bytes, url-safe base64 with the trailing "=".
ephemeral "random_bytes" "fernet" {
  length = 32
}

locals {
  generated_value = (contains(local.fernet_keys, var.secret)
    ? replace(replace(ephemeral.random_bytes.fernet.base64, "+", "-"), "/", "_")
    : ephemeral.random_password.long.result
  )
  final = var.value != "" ? var.value : local.generated_value
}

resource "google_secret_manager_secret_version" "new" {
  secret = "projects/${var.project_id}/secrets/${var.secret}"

  secret_data_wo = local.final
  # Changes on every run: that is what makes each apply write a new version.
  secret_data_wo_version = parseint(formatdate("YYYYMMDDhhmmss", plantimestamp()), 10)

  # When replaced, the previous version stays in Secret Manager.
  deletion_policy = "ABANDON"

  lifecycle {
    precondition {
      condition     = var.value != "" || contains(local.generated, var.secret)
      error_message = "That secret comes from outside (database, payment provider, mail...): paste the value, it cannot be generated."
    }
    precondition {
      condition     = !contains(keys(local.must_start_with), var.secret) || startswith(var.value, lookup(local.must_start_with, var.secret, ""))
      error_message = "That value does not have the expected format (see must_start_with in secrets/main.tf)."
    }
  }
}

output "loaded" {
  description = "Which version was written."
  value       = "${var.secret}: version ${google_secret_manager_secret_version.new.version}"
}
