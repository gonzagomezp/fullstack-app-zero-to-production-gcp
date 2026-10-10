# Secret Manager: the CONTAINERS and who reads each one. VALUES never go through here (nor into the
# state): they are loaded with `terraform -chdir=infra/secrets apply`, which asks which and its value.

locals {
  # secret -> services that read it. Adapt to the app. Fronts only ever see api-key.
  secrets = {
    "api-key"        = ["api", "dashboard", "static", "admin", "webhooks"]
    "jwt-secret"     = ["api"]
    "db-uri"         = ["api"]
    "webhook-secret" = ["webhooks"]
  }

  secret_reads = merge([
    for secret, readers in local.secrets : {
      for reader in readers : "${secret}/${reader}" => { secret = secret, service = reader }
      if contains(keys(local.services), reader)
    }
  ]...)
}

resource "google_secret_manager_secret" "secret" {
  for_each = local.secrets

  secret_id = each.key

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.api]
}

resource "google_secret_manager_secret_iam_member" "read" {
  for_each = local.secret_reads

  secret_id = google_secret_manager_secret.secret[each.value.secret].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.runtime[each.value.service].member
}

# Every mounted secret must have a value. Checked here, at plan time, so a missing one fails with its
# name instead of a service that does not start. Metadata only: the value is not read.
data "google_secret_manager_secret_version" "mounted" {
  for_each = toset(distinct(flatten([for s in local.services : values(s.secrets)])))

  secret            = google_secret_manager_secret.secret[each.value].secret_id
  fetch_secret_data = false
}
