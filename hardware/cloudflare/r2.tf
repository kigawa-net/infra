resource "cloudflare_r2_bucket" "kaft" {
  account_id = var.account_id
  name       = "kaft"
  location   = "APAC"
}
