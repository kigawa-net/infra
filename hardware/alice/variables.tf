variable "host" {
  type    = string
  default = "161.248.62.66"
}

variable "ssh_user" {
  type    = string
  default = "root"
}

variable "ssh_key_bitwarden_id" {
  type    = string
  default = "0393671f-6ef0-4650-be98-b364013f8644"
}

variable "sudo_password_bitwarden_id" {
  type    = string
  default = "52b44d60-7cab-429f-929a-b4340139b6d8"
}

variable "inuyama_wireguard_private_key_bitwarden_id" {
  description = "Bitwarden ID for the inuyama WireGuard private key. The alice module records the ID but does not read this secret."
  type        = string
  default     = "549fe18f-afa9-477e-b4ce-b45f0033e8f2"
}

variable "inuyama_wireguard_public_key_bitwarden_id" {
  type    = string
  default = "b389e2ea-5b86-4bbf-b795-b45f00340001"
}

variable "hostname" {
  type    = string
  default = "alice-01"
}

variable "wireguard_interface" {
  type    = string
  default = "wg0"
}

variable "wireguard_listen_port" {
  type    = number
  default = 51820
}

variable "wireguard_address" {
  type    = string
  default = "172.31.255.2/30"
}

variable "wireguard_mtu" {
  type    = number
  default = 1420
}

variable "wireguard_peer_allowed_ips" {
  type = list(string)
  default = [
    "172.31.255.1/32",
    "10.0.0.0/16", # Inuyama Site Network (Supernet)
  ]
}

variable "wireguard_persistent_keepalive" {
  type    = number
  default = 25
}

variable "inuyama_wireguard_address" {
  type    = string
  default = "172.31.255.1"
}

variable "inuyama_wireguard_endpoint" {
  description = "Optional public endpoint for the inuyama WireGuard peer. Alice can omit this when inuyama dials alice."
  type        = string
  default     = ""
}

variable "alice_asn" {
  type    = number
  default = 65020
}

variable "inuyama_asn" {
  type    = number
  default = 65010
}

variable "bgp_router_id" {
  type    = string
  default = "172.31.255.2"
}

variable "inuyama_accepted_prefixes" {
  type = list(string)
  default = [
    "10.0.0.0/16",
  ]
}

variable "alice_advertised_prefixes" {
  type    = list(string)
  default = []
}

variable "inuyama_ingress_vip" {
  description = "Inuyama ingress VIP for alice HTTP/HTTPS forwarding. Empty disables those HAProxy frontends."
  type        = string
  default     = "10.0.1.240"
}

variable "minecraft_backend_vip" {
  description = "Inuyama Minecraft backend VIP for alice TCP/25565 forwarding. Empty disables that HAProxy frontend."
  type        = string
  default     = "10.0.1.241"
}

variable "manage_firewall" {
  type    = bool
  default = true
}

variable "firewall_ssh_port" {
  type    = number
  default = 22
}
