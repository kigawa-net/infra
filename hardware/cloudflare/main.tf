data "external" "api_token" {
  program = ["bash", "-c", <<-EOT
    value=$(bws secret get "${var.api_token_bitwarden_id}" --color no | jq -r '.value')
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

provider "cloudflare" {
  api_token = data.external.api_token.result.value
}

resource "cloudflare_zone_settings_override" "kigawa_net" {
  zone_id = var.zone_id

  settings {
    ssl              = "full"
    min_tls_version  = "1.0"
    always_use_https = "on"
    tls_1_3          = "on"
  }
}

# --- A records ---

resource "cloudflare_record" "base" {
  zone_id = var.zone_id
  name    = "base"
  type    = "A"
  content = "74.208.55.86"
  ttl     = 1
  proxied = false
}

resource "cloudflare_record" "diver" {
  zone_id = var.zone_id
  name    = "diver"
  type    = "A"
  content = "74.208.55.86"
  ttl     = 1
  proxied = false
}

resource "cloudflare_record" "ftb" {
  zone_id = var.zone_id
  name    = "ftb"
  type    = "A"
  content = "74.208.55.86"
  ttl     = 1
  proxied = false
}

resource "cloudflare_record" "harbor" {
  zone_id = var.zone_id
  name    = "harbor"
  type    = "A"
  content = "74.208.55.86"
  ttl     = 1
  proxied = false
}

resource "cloudflare_record" "k8s" {
  zone_id = var.zone_id
  name    = "k8s"
  type    = "A"
  content = "74.208.55.86"
  ttl     = 1
  proxied = false
}

resource "cloudflare_record" "web_base" {
  zone_id = var.zone_id
  name    = "web-base"
  type    = "A"
  content = "74.208.55.86"
  ttl     = 1
  proxied = true
}

# --- CNAME records ---

resource "cloudflare_record" "el4s_realtime" {
  zone_id = var.zone_id
  name    = "el4s-realtime"
  type    = "CNAME"
  content = "base.kigawa.net"
  ttl     = 1
  proxied = false
}

resource "cloudflare_record" "wildcard" {
  zone_id = var.zone_id
  name    = "*"
  type    = "CNAME"
  content = "web-base.kigawa.net"
  ttl     = 1
  proxied = true
}

resource "cloudflare_record" "apex" {
  zone_id = var.zone_id
  name    = "kigawa.net"
  type    = "CNAME"
  content = "web-base.kigawa.net"
  ttl     = 1
  proxied = true
}

resource "cloudflare_record" "kizuna" {
  zone_id = var.zone_id
  name    = "kizuna"
  type    = "CNAME"
  content = "base.kigawa.net"
  ttl     = 1
  proxied = false
}

resource "cloudflare_record" "mc" {
  zone_id = var.zone_id
  name    = "mc"
  type    = "CNAME"
  content = "base.kigawa.net"
  ttl     = 1
  proxied = false
}

resource "cloudflare_record" "nextcloud" {
  zone_id = var.zone_id
  name    = "nextcloud"
  type    = "CNAME"
  content = "base.kigawa.net"
  ttl     = 1
  proxied = false
}

resource "cloudflare_record" "ssh" {
  zone_id = var.zone_id
  name    = "ssh"
  type    = "CNAME"
  content = "base.kigawa.net"
  ttl     = 1
  proxied = false
}

# --- MX ---

resource "cloudflare_record" "mx" {
  zone_id  = var.zone_id
  name     = "kigawa.net"
  type     = "MX"
  content  = "kigawa.sakura.ne.jp"
  priority = 0
  ttl      = 1
}

# --- TXT (ACME DNS-01 challenge records are intentionally excluded ---
# --- here: certbot/acme.sh creates and deletes them dynamically,   ---
# --- so managing them via Terraform would fight the ACME client.) ---

resource "cloudflare_record" "atproto" {
  zone_id = var.zone_id
  name    = "_atproto"
  type    = "TXT"
  content = "\"did=did:plc:akaxu3viygesttyih7nevcgk\""
  ttl     = 1
}

resource "cloudflare_record" "discord" {
  zone_id = var.zone_id
  name    = "_discord"
  type    = "TXT"
  content = "\"dh=506b0be919d51deb7c082fbebe39aa62dad603fb\""
  ttl     = 1
}

resource "cloudflare_record" "dmarc" {
  zone_id = var.zone_id
  name    = "_dmarc"
  type    = "TXT"
  content = "v=DMARC1; p=quarantine; aspf=r; adkim=r"
  ttl     = 1
}

resource "cloudflare_record" "spf" {
  zone_id = var.zone_id
  name    = "kigawa.net"
  type    = "TXT"
  content = "\"v=spf1 a:www2160.sakura.ne.jp mx include:freee.co.jp ~all\""
  ttl     = 1
}

resource "cloudflare_record" "google_site_verification" {
  zone_id = var.zone_id
  name    = "kigawa.net"
  type    = "TXT"
  content = "google-site-verification=3lzpJLM259kL4oLJDOQOwBTX8p1oPaOzrTix8eM5JZM"
  ttl     = 3600
}

resource "cloudflare_record" "dkim" {
  zone_id = var.zone_id
  name    = "rs20240819._domainkey"
  type    = "TXT"
  content = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAu99alb+1txhBtW+cQ3Cq12bPZMD1mZ5IDYgV/sh73cb+QV6l/WvXGuea0ew1woNvobLKByA6SCSliI4sibQ1V8Yh/A3zC/IOxccUu0hmd36BalMXbarKX9UZRMARcd1mrsmQ+4VLXyHj7RkDHgaiprHduobs6/qUZWgFkRjH1CCDbgc08Cd6sxc2APwlynJO/zNCdnQx+kNaMTz9I3Xtf2tU9xbZWJur2UcQfbSKs0Z3ZY+5pkRFpspMDCAWDQb/nZNaMd0ADaZVkMmqu0BxX7EBbjoUZ39I3uYZBIVuTw6+iuVzZ+sLhkpQOefcQ0CyZ3n4PThCx2YWE2OyZaQ4gQIDAQAB"
  ttl     = 1
}
