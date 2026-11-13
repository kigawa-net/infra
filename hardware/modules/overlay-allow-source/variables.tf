variable "host" {
  description = "接続先(SSH)。control-plane の IP"
  type        = string
}

variable "ssh_user" {
  type = string
}

variable "ssh_private_key" {
  type      = string
  sensitive = true
}

variable "sudo_password" {
  description = "root 以外で接続するときの sudo パスワード"
  type        = string
  sensitive   = true
  default     = ""
}

variable "sources" {
  description = <<-EOT
    Overlay 側で、TCP を INPUT の先頭で許可する送信元(IP または CIDR)。CI(GitHub のランナー)の Overlay のアドレスだけを入れる。
    空(既定)なら、何もしない。
    注意: Overlay の識別は、network_secret だけ(Secure Mode は無効)。network_secret を知る者が、同じアドレスを名乗って参加すれば、
    この許可の対象になる。許可するのは、サブネットプロキシ経由の TCP(k8s4 自身のポートにも届く)。Secure Mode を有効にするときは、ランナーの credential も要る。
  EOT
  type        = list(string)
  default     = []
}
