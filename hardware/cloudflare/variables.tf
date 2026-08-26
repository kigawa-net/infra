variable "api_token_bitwarden_id" {
  description = "Cloudflare APIトークンのBitwarden ID (Zone:DNS:Edit, Zone:Zone:Read 権限)"
  type        = string
  default     = "2ca12501-85e3-4b5b-a4e7-b4a201031365"
}

variable "zone_id" {
  description = "kigawa.net の Cloudflare Zone ID"
  type        = string
  default     = "ac52b110a9b655a56a9738d95bc28591"
}

variable "account_id" {
  description = "Cloudflare アカウントID（R2バケット等アカウントスコープのリソース管理に使用）"
  type        = string
  default     = "e9f30fd43ef4cc3d46050e34dad5c811"
}
