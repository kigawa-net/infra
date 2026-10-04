variable "host" {
  description = "k8s-worker4 の自宅 LAN のアドレス。CI(GitHub-hosted runner)から、WireGuard(ionos → k8s4 の ci-ssh-forward)経由で SSH する"
  type        = string
  default     = "192.168.1.121"
}

variable "ssh_user" {
  type    = string
  default = "kigawa"
}

variable "control_plane_ssh_key_bitwarden_id" {
  type    = string
  default = "0393671f-6ef0-4650-be98-b364013f8644"
}

variable "sudo_password_bitwarden_id" {
  type    = string
  default = "52b44d60-7cab-429f-929a-b4340139b6d8"
}
