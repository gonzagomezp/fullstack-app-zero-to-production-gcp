output "images" {
  description = "Image each service runs."
  value       = local.image
}

output "api_url" {
  description = "run.app URL of the (internal) api."
  value       = local.api_url
}

output "wif_provider" {
  description = "For the WIF_PROVIDER variable of GitHub Actions."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "deployer_sa" {
  description = "For the DEPLOYER_SA variable of GitHub Actions."
  value       = google_service_account.deployer.email
}

output "dns_records" {
  description = "What to load in the DNS for each domain."
  value = {
    for s, mapping in google_cloud_run_domain_mapping.domain :
    mapping.name => [for r in mapping.status[0].resource_records : "${r.type} ${r.rrdata}"]
  }
}
