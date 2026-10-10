# One service account per service (least privilege), GitHub Actions without keys, and who can do
# what. All loose bindings (`_member`): Terraform adds its own and never removes ones it does not know.

resource "google_service_account" "runtime" {
  for_each = local.services

  account_id   = "${var.app}-${each.key}-run"
  display_name = "Runtime: ${each.key}"
}

# Cloud Scheduler and Cloud Tasks call the api with this identity's OIDC token.
resource "google_service_account" "invoker" {
  account_id   = "${var.app}-invoker"
  display_name = "Cloud Scheduler + Cloud Tasks -> api"
}

# GitHub Actions: pushes images and swaps each service's image. Nothing else.
resource "google_service_account" "deployer" {
  account_id   = "${var.app}-deployer"
  display_name = "CI (GitHub Actions)"
}

# --- Workload Identity Federation ------------------------------------------------------------------

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions"

  depends_on = [google_project_service.api]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }

  # Bound to the repo: without it, ANY GitHub repo could ask for a token.
  attribute_condition = "assertion.repository == '${var.github_repo}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "github_uses_deployer" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}

# --- CI: push images and swap the image of each service ---------------------------------------------

resource "google_artifact_registry_repository_iam_member" "deployer_writes" {
  repository = google_artifact_registry_repository.images.name
  location   = google_artifact_registry_repository.images.location
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.deployer.member
}

# Only on these services, not on Cloud Run project-wide. IAM cannot restrict it to "only the image":
# if CI touched the config, the next `terraform plan` shows the drift and `apply` reverts it.
resource "google_cloud_run_v2_service_iam_member" "deployer_updates" {
  for_each = local.services

  name     = google_cloud_run_v2_service.service[each.key].name
  location = var.region
  role     = "roles/run.developer"
  member   = google_service_account.deployer.member
}

# A new revision runs as its service's runtime account: whoever creates it must be able to act as it.
resource "google_service_account_iam_member" "deployer_acts_as_runtime" {
  for_each = local.services

  service_account_id = google_service_account.runtime[each.key].name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.deployer.member
}

# --- Runtime permissions (adapt to the app) ---------------------------------------------------------

# api: enqueue Cloud Tasks and sign their OIDC token as the invoker account.
resource "google_project_iam_member" "api_enqueues" {
  project = var.project_id
  role    = "roles/cloudtasks.enqueuer"
  member  = google_service_account.runtime["api"].member
}

resource "google_service_account_iam_member" "api_acts_as_invoker" {
  service_account_id = google_service_account.invoker.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.runtime["api"].member
}

# api: the only writer of the private bucket.
resource "google_storage_bucket_iam_member" "api_files" {
  bucket = google_storage_bucket.files.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.runtime["api"].member
}

# --- Who invokes the api (nobody else) --------------------------------------------------------------

locals {
  api_callers = merge(
    { for s, cfg in local.services : s => google_service_account.runtime[s].member if cfg.calls_api },
    { invoker = google_service_account.invoker.member },
  )
}

resource "google_cloud_run_v2_service_iam_member" "api_invoked_by" {
  for_each = local.api_callers

  name     = google_cloud_run_v2_service.service["api"].name
  location = var.region
  role     = "roles/run.invoker"
  member   = each.value
}
