variable "host" {
  type    = string
  default = "192.168.1.30"
}

variable "ssh_user" {
  type    = string
  default = "kigawa"
}

variable "ssh_key_bitwarden_id" {
  type    = string
  default = "0393671f-6ef0-4650-be98-b364013f8644"
}

variable "sudo_password_bitwarden_id" {
  type    = string
  default = "52b44d60-7cab-429f-929a-b4340139b6d8"
}

variable "k8s_version" {
  type    = string
  default = "1.29"
}

variable "k8s_endpoint" {
  type    = string
  default = "192.168.1.103"
}

variable "control_plane_host" {
  type    = string
  default = "192.168.1.103"
}

variable "control_plane_ssh_user" {
  type    = string
  default = "kigawa"
}

variable "pod_network_cidr" {
  type    = string
  default = "10.244.0.0/16"
}

variable "cni_manifest_url" {
  type    = string
  default = "https://raw.githubusercontent.com/flannel-io/flannel/v0.27.3/Documentation/kube-flannel.yml"
}

variable "bgp_local_as" {
  type    = number
  default = 64512
}

variable "bgp_peers" {
  type = list(object({
    ip   = string
    as   = number
  }))
  default = []
}
