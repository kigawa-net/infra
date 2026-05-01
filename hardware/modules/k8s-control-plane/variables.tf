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

variable "k8s_version" {
  description = "Kubernetes minor version (e.g. 1.32)"
  type        = string
}

variable "k8s_endpoint" {
  type = string
}

variable "pod_network_cidr" {
  description = "kubeadm init 時のpod network CIDR (join時は無視)"
  type        = string
  default     = "10.244.0.0/16"
}

variable "cni_manifest_url" {
  description = "kubeadm init 後に適用するCNIマニフェストURL (join時は無視)"
  type        = string
  default     = "https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"
}

variable "join_token" {
  description = "kubeadm join トークン。空の場合はkubeadm initを実行"
  type        = string
  default     = ""
}

variable "join_ca_cert_hash" {
  type    = string
  default = ""
}

variable "join_certificate_key" {
  type    = string
  default = ""
}
