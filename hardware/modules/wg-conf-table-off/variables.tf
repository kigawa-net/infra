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

variable "interfaces" {
  description = "`Table = off` を入れる wg-quick のインターフェースと、PostUp に足すコマンド(1 行ずつ。`%i` はインターフェース名に展開される)。post_up が空なら、Table = off だけ。AllowedIPs からの自動経路の代わりに、必要な経路だけを、`ip route replace` で入れる"
  type = map(object({
    post_up = list(string)
  }))
}
