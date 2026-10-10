variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "Region for Cloud Run, Artifact Registry, Tasks and Scheduler. Same as the database."
  type        = string
  default     = "us-central1"
}

variable "app" {
  description = "Short app name. Prefixes service, service-account and repository names (<app>-api, <app>-api-run)."
  type        = string
}

variable "domain" {
  description = "Product domain. The apex goes to the public front; subdomains to the others (see services.tf)."
  type        = string
}

variable "github_repo" {
  description = "GitHub repo (owner/name) allowed to push images and update service images through Workload Identity Federation."
  type        = string
}

# --- Which image runs -------------------------------------------------------------------------------

variable "images" {
  description = <<-EOT
    Tag (short SHA) to run per service. Empty = the latest TAGGED image in Artifact Registry. Pinning
    one is how you roll back:  terraform apply -var 'images={api="0ed9d4b"}'
    It lasts while the variable is passed: the next push deploys the new image again.
  EOT
  type        = map(string)
  default     = {}
}

# --- Non-secret config (put the real values in terraform.tfvars) -------------------------------------

variable "google_oauth_client_id" {
  description = "Google OAuth client ID (login). Not a secret: it ships in the HTML. Empty = no Google login."
  type        = string
  default     = ""
}

variable "superadmin_email" {
  description = "Superadmin email, seeded by the api at startup (see the `login` module)."
  type        = string
  default     = ""
}

variable "api_url" {
  description = <<-EOT
    run.app URL of the api, used by the fronts, the crons and the api itself (OIDC audience). A service
    cannot read its own URL in Terraform, so it is written. Empty = the deterministic URL
    (https://<app>-api-<project number>.<region>.run.app). When ADOPTING an existing project, write the
    URL it already uses so nothing changes.
  EOT
  type        = string
  default     = ""
}

# --- Secrets -------------------------------------------------------------------------------------------

variable "optional_secrets" {
  description = <<-EOT
    Optional secrets that get mounted. One not listed is not mounted and that feature stays off.
    Load its value BEFORE listing it:  terraform -chdir=infra/secrets apply
  EOT
  type        = set(string)
  default     = []
}

# --- Budget alert --------------------------------------------------------------------------------------

variable "billing_account" {
  description = "Billing account for the budget alert. Empty = Terraform does not manage it (needs permission on that account)."
  type        = string
  default     = ""
}

variable "budget_usd" {
  description = "Monthly budget alert in USD. Mails billing admins at 50/90/100 %; never stops anything."
  type        = number
  default     = 20
}
