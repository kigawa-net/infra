variable "host" {
  type = string
}

variable "ssh_user" {
  type = string
}

variable "ssh_private_key" {
  type      = string
  sensitive = true
}

variable "sudo_password" {
  type      = string
  sensitive = true
}

variable "ssh_port" {
  description = "sshd が待ち受ける tcp ポート。公開のまま許可する(GitHub-hosted runner は送信元を絞れないので、鍵認証のみで守る)"
  type        = number
  default     = 22
}

variable "wireguard_interface" {
  description = "WireGuard のインターフェース名。このインターフェースから入る通信だけに、tcp_ports_on_wireguard を許可する"
  type        = string
  default     = "wg0"
}

variable "wireguard_hub_address" {
  description = "WireGuard のハブ(IONOS)の公開アドレス。ここからの UDP を許可する(ハンドシェイクの再交渉は、ハブから来ることがある)"
  type        = string
}

variable "tcp_ports_on_wireguard" {
  description = "wireguard_interface 上の受信だけ許可する tcp ポート(OpenBao の API 8200 と cluster 8201 など)"
  type        = list(number)
  default     = []
}

variable "extra_interfaces" {
  description = "tcp_ports_on_wireguard を、wireguard_interface に加えて許可するインターフェース(EasyTier のオーバーレイ tun0 など)。Raft を、ハブを通らない経路(オーバーレイ)でも通せるようにする。存在しないインターフェースでも、ufw のルールは作れる"
  type        = list(string)
  default     = []
}
