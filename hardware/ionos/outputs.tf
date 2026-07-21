output "host" {
  value = var.host
}

output "wireguard_interface" {
  value = var.wireguard_interface
}

output "wireguard_endpoint" {
  value = "${var.host}:${var.wireguard_listen_port}"
}

output "wireguard_address" {
  value = var.wireguard_address
}

output "ionos_public_key_path" {
  value = "/etc/wireguard/ionos_public.key"
}

output "frr_config_path" {
  value = "/etc/frr/frr.conf"
}

output "haproxy_config_path" {
  value = "/etc/haproxy/haproxy.cfg"
}

output "haproxy_enabled" {
  value = local.haproxy_enabled
}
