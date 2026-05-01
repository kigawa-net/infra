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

variable "bird_image" {
  type    = string
  default = "kathara/bird2:latest"
}

variable "bgp_router_id" {
  description = "BIRDのrouter ID (通常はノードのIP)"
  type        = string
}

variable "bgp_local_as" {
  description = "ローカルAS番号"
  type        = number
  default     = 65000
}

variable "bgp_peers" {
  description = "iBGPピアのIPリスト (全て同じAS番号を使用)"
  type        = list(string)
  default     = []
}
