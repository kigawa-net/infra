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

variable "destination_cidr" {
  description = "この経路で到達させたい宛先CIDR(クラスタLAN)"
  type        = string
  default     = "10.0.0.0/24"
}

variable "gateways" {
  description = "宛先CIDRへのnext-hopとして使う、同一L2セグメント上のIP forwarding有効なノード群(通常はk8s1/k8s2/k8s4の自宅LAN側アドレス)。複数指定するとECMPで冗長化される"
  type        = list(string)
}
