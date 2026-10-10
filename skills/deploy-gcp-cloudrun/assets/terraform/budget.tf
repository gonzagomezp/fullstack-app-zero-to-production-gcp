# Budget alert: mails the billing admins at 50/90/100 %. It warns; it never stops anything. It lives
# on the billing account (often shared with other projects): with no `billing_account`, or without
# permission on it, Terraform does not manage it.

resource "google_billing_budget" "alert" {
  count    = var.billing_account != "" ? 1 : 0
  provider = google.billing

  billing_account = var.billing_account
  display_name    = "${var.project_id} · USD ${var.budget_usd}"

  budget_filter {
    projects        = ["projects/${data.google_project.this.number}"]
    calendar_period = "MONTH"
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_usd)
    }
  }

  dynamic "threshold_rules" {
    for_each = [0.5, 0.9, 1.0]
    content {
      threshold_percent = threshold_rules.value
    }
  }

  depends_on = [google_project_service.api]
}
