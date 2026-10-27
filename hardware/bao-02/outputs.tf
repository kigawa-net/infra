output "api_addr" {
  description = "bao-02 の API のアドレス(WireGuard 上)。enabled = false のときは null"
  value       = var.enabled ? "https://${var.wg_address}:8200" : null
}
