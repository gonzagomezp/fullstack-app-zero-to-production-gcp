# Project-level pieces: APIs, image registry, private bucket, task queue, network check.

locals {
  # Add the APIs the app uses (aiplatform for Vertex/Gemini, cloudtasks/cloudscheduler if there are
  # queues/crons, drive/picker for Google Drive...). compute: Direct VPC egress uses the default subnet.
  apis = [
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "storage.googleapis.com",
    "compute.googleapis.com",
    "cloudtasks.googleapis.com",
    "cloudscheduler.googleapis.com",
    "billingbudgets.googleapis.com",
  ]
}

resource "google_project_service" "api" {
  for_each = toset(local.apis)

  service            = each.value
  disable_on_destroy = false
}

# --- Artifact Registry --------------------------------------------------------------------------------

resource "google_artifact_registry_repository" "images" {
  repository_id = var.app
  location      = var.region
  format        = "DOCKER"
  description   = "Docker images of ${var.app}"

  # An image tag is never overwritten: rolling back to an old tag brings back exactly that image.
  docker_config {
    immutable_tags = true
  }

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "delete-old-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "86400s"
    }
  }

  cleanup_policies {
    id     = "keep-last-15"
    action = "KEEP"
    most_recent_versions {
      keep_count = 15
    }
  }

  depends_on = [google_project_service.api]
}

# --- Private bucket (uploads). Delete this block if the app stores no files --------------------------

resource "google_storage_bucket" "files" {
  name     = "${var.project_id}-files"
  location = upper(var.region)

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  lifecycle {
    prevent_destroy = true
  }
}

# --- Cloud Tasks queue. Delete if the app has no async jobs -------------------------------------------

resource "google_cloud_tasks_queue" "jobs" {
  name     = "jobs"
  location = var.region

  rate_limits {
    max_concurrent_dispatches = 5
    max_dispatches_per_second = 2
  }

  retry_config {
    max_attempts  = 4
    min_backoff   = "10s"
    max_backoff   = "300s"
    max_doublings = 16
  }

  depends_on = [google_project_service.api]
}

# --- Network -------------------------------------------------------------------------------------------
# Fronts reach the internal api through Direct VPC egress on the `default` subnet, which needs Private
# Google Access. The subnet is created by Google with the default network: checked, not managed.

data "google_compute_subnetwork" "default" {
  name   = "default"
  region = var.region

  depends_on = [google_project_service.api]
}

check "private_google_access" {
  assert {
    condition     = data.google_compute_subnetwork.default.private_ip_google_access
    error_message = "Subnet default in ${var.region} has no Private Google Access: the fronts will not reach the api. Fix: gcloud compute networks subnets update default --region=${var.region} --enable-private-ip-google-access"
  }
}
