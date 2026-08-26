resource "cloudflare_r2_bucket" "kaft" {
  account_id = var.account_id
  name       = "kaft"
  location   = "APAC"
}

resource "cloudflare_r2_bucket" "kaft_stg" {
  account_id = var.account_id
  name       = "kaft-stg"
  location   = "APAC"
}

resource "cloudflare_r2_bucket" "kaft_dev" {
  account_id = var.account_id
  name       = "kaft-dev"
  location   = "APAC"
}
