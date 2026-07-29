output "public_key" {
  description = "このノードの WireGuard 公開鍵"
  value       = data.external.public_key.result.value
}
