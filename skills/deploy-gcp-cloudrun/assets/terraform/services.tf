# The Cloud Run services with their COMPLETE config. Changing an env var, a mounted secret, memory, a
# cron or a permission = edit here and `terraform apply` (by hand). CI only swaps the image.
#
# Delete the services this app does not have. Keys = folder/image names (api, dashboard, static,
# admin, webhooks) and the suffix of the Cloud Run service (<app>-<key>).

locals {
  url = {
    static    = "https://${var.domain}"
    dashboard = "https://dashboard.${var.domain}"
    admin     = "https://admin.${var.domain}"
    webhooks  = "https://webhooks.${var.domain}"
  }

  # Written or computed, never read from the resource: all services come from one block and one cannot
  # reference another. The `check` below warns if it stops matching reality.
  api_url = var.api_url != "" ? var.api_url : "https://${var.app}-api-${data.google_project.this.number}.${var.region}.run.app"

  services = {
    # Internal. Keeps its run.app URL: Cloud Scheduler and Cloud Tasks only count as internal traffic
    # through the default URL. No VPC egress: it goes straight to the DB and third-party APIs.
    api = {
      ingress   = "INGRESS_TRAFFIC_INTERNAL_ONLY"
      public    = false
      run_url   = true
      vpc       = false
      calls_api = false
      memory    = "1Gi"
      timeout   = "300s"
      audiences = []
      env = {
        GOOGLE_CLOUD_PROJECT   = var.project_id
        API_URL                = local.api_url # OIDC audience the api re-checks on /cron and /internal
        INVOKER_SA_EMAIL       = google_service_account.invoker.email
        GCS_BUCKET             = google_storage_bucket.files.name
        TASKS_QUEUE            = google_cloud_tasks_queue.jobs.name
        TASKS_LOCATION         = var.region
        DASHBOARD_URL          = local.url.dashboard
        SUPERADMIN_EMAIL       = var.superadmin_email
        GOOGLE_OAUTH_CLIENT_ID = var.google_oauth_client_id
      }
      # Required ones, then the optional ones that are listed in var.optional_secrets.
      secrets = merge(
        {
          API_KEY    = "api-key"
          JWT_SECRET = "jwt-secret"
          DB_URI     = "db-uri"
        },
        { for env_name, secret in {} : env_name => secret if contains(var.optional_secrets, secret) },
      )
    }

    # Public fronts. Direct VPC egress ALL traffic is what lets them reach the internal api (without it
    # the Google Front End answers 404). Consequence: without Cloud NAT they have NO internet egress.
    dashboard = {
      ingress   = "INGRESS_TRAFFIC_ALL"
      public    = true
      run_url   = false
      vpc       = true
      calls_api = true
      memory    = "1Gi"
      timeout   = "300s"
      audiences = []
      env = {
        BACKEND_URL            = local.api_url
        PUBLIC_URL             = local.url.dashboard
        GOOGLE_OAUTH_CLIENT_ID = var.google_oauth_client_id
      }
      secrets = { API_KEY = "api-key" }
    }

    static = {
      ingress   = "INGRESS_TRAFFIC_ALL"
      public    = true
      run_url   = false
      vpc       = true
      calls_api = true
      memory    = "512Mi"
      timeout   = "300s"
      audiences = []
      env       = { BACKEND_URL = local.api_url }
      secrets   = { API_KEY = "api-key" }
    }

    admin = {
      ingress   = "INGRESS_TRAFFIC_ALL"
      public    = true # own login
      run_url   = false
      vpc       = true
      calls_api = true
      memory    = "512Mi"
      timeout   = "300s"
      audiences = []
      env = {
        BACKEND_URL            = local.api_url
        GOOGLE_OAUTH_CLIENT_ID = var.google_oauth_client_id
      }
      secrets = { API_KEY = "api-key" }
    }

    # The provider's signature is the auth: without webhook-secret it rejects every notice.
    webhooks = {
      ingress   = "INGRESS_TRAFFIC_ALL"
      public    = true
      run_url   = false
      vpc       = true
      calls_api = true
      memory    = "512Mi"
      timeout   = "300s"
      audiences = []
      env       = { BACKEND_URL = local.api_url }
      secrets = {
        API_KEY        = "api-key"
        WEBHOOK_SECRET = "webhook-secret"
      }
    }
  }
}

# --- Which image each service runs ---------------------------------------------------------------------
# CI builds and pushes `<service>:<short sha>` and swaps the image. Here the LATEST TAGGED image of each
# service is taken — the one CI just deployed, so `plan` shows no changes after a push. Not "the latest
# modified": next to each image the build leaves untagged manifests (platform image, attestation) with
# the same timestamp, and the data source's "latest" can return one of those.

data "google_artifact_registry_docker_images" "all" {
  location      = google_artifact_registry_repository.images.location
  repository_id = google_artifact_registry_repository.images.repository_id
}

locals {
  registry = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"

  # Per service, "time|tag" of every tagged image, oldest first.
  tagged = {
    for service in keys(local.services) : service => sort([
      for i in data.google_artifact_registry_docker_images.all.docker_images :
      "${i.update_time}|${i.tags[0]}"
      if length(i.tags) > 0 && startswith(i.self_link, "${local.registry}/${service}@")
    ])
  }

  image = {
    for service in keys(local.services) : service => (
      lookup(var.images, service, "") != "" ? "${local.registry}/${service}:${var.images[service]}"
      : length(local.tagged[service]) > 0 ? "${local.registry}/${service}:${split("|", reverse(local.tagged[service])[0])[1]}"
      # Brand-new project with no images yet: Google's sample image until CI pushes the real one.
      : "us-docker.pkg.dev/cloudrun/container/hello"
    )
  }
}

resource "google_cloud_run_v2_service" "service" {
  for_each = local.services

  name     = "${var.app}-${each.key}"
  location = var.region
  ingress  = each.value.ingress

  # Public services WITHOUT `allUsers`: under an organization with domain-restricted sharing
  # (iam.allowedPolicyMemberDomains) `allUsers` cannot be granted; disabling the invoker check is what
  # Google recommends for public services there. Private ones keep the IAM check.
  invoker_iam_disabled = each.value.public
  default_uri_disabled = !each.value.run_url
  # A private service with public ingress (called with an ID token whose audience is its own domain).
  custom_audiences = length(each.value.audiences) > 0 ? each.value.audiences : null

  deletion_protection = true

  template {
    service_account                  = google_service_account.runtime[each.key].email
    timeout                          = each.value.timeout
    max_instance_request_concurrency = 80

    # Scale to zero (no traffic = no cost) and a cap that bounds the bill if someone hammers it.
    scaling {
      min_instance_count = 0
      max_instance_count = 5
    }

    dynamic "vpc_access" {
      for_each = each.value.vpc ? [1] : []
      content {
        egress = "ALL_TRAFFIC"
        network_interfaces {
          network    = "default"
          subnetwork = "default"
        }
      }
    }

    containers {
      image = local.image[each.key]

      resources {
        limits = {
          cpu    = "1"
          memory = each.value.memory
        }
        cpu_idle          = true # CPU only while serving a request
        startup_cpu_boost = true
      }

      dynamic "env" {
        for_each = each.value.env
        content {
          name  = env.key
          value = env.value
        }
      }

      # `latest`: resolved when each instance starts, so a new value reaches new instances by itself.
      dynamic "env" {
        for_each = each.value.secrets
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.secret[env.value].secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }

  lifecycle {
    # Set by whoever deployed last (gcloud from CI, the console): not config.
    ignore_changes = [client, client_version]
  }

  depends_on = [
    google_project_service.api,
    google_secret_manager_secret_iam_member.read,
    data.google_secret_manager_secret_version.mounted,
  ]
}

check "api_url" {
  assert {
    condition     = contains(google_cloud_run_v2_service.service["api"].urls, local.api_url)
    error_message = "api_url (${local.api_url}) is not a URL of the api service: fronts and crons are talking to something else. Fix api_url in terraform.tfvars."
  }
}

# --- Daily crons (delete the block if there are none) ------------------------------------------------

locals {
  crons = {
    # name = { schedule = "5 0 * * *", path = "/cron/something" }
  }
}

resource "google_cloud_scheduler_job" "cron" {
  for_each = local.crons

  name             = "${var.app}-${each.key}"
  region           = var.region
  schedule         = each.value.schedule
  time_zone        = "America/Argentina/Buenos_Aires"
  attempt_deadline = "300s"

  http_target {
    uri         = "${local.api_url}${each.value.path}"
    http_method = "POST"

    # The api validates this token again: audience = its own URL.
    oidc_token {
      service_account_email = google_service_account.invoker.email
      audience              = local.api_url
    }
  }

  # Scheduler's defaults, written so an imported job shows no diff.
  retry_config {
    retry_count          = 0
    max_retry_duration   = "0s"
    min_backoff_duration = "5s"
    max_backoff_duration = "3600s"
    max_doublings        = 16
  }

  depends_on = [google_project_service.api]
}

# --- Domains ------------------------------------------------------------------------------------------
# Native Cloud Run domain mapping. Verify the domain once first: gcloud domains verify <domain>.
# DNS in Cloudflare with proxy (orange cloud) works: Google's certificate is issued anyway, it just
# takes a bit longer. Apex -> A/AAAA; subdomains -> CNAME ghs.googlehosted.com (output dns_records).

resource "google_cloud_run_domain_mapping" "domain" {
  for_each = { for s, u in local.url : s => trimprefix(u, "https://") if contains(keys(local.services), s) }

  name     = each.value
  location = var.region

  metadata {
    namespace = var.project_id
  }

  spec {
    route_name = google_cloud_run_v2_service.service[each.key].name
  }
}
