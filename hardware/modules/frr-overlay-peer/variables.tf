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

variable "router_id" {
  description = "FRR の router-id と、BGP セッションの送信元(overlay の IP。例: bao-02 は 10.250.0.1)。overlay 上の、このノードの IPv4 アドレス(単独)"
  type        = string

  validation {
    condition     = can(cidrhost("${var.router_id}/32", 0))
    error_message = "router_id は IPv4 のアドレスだけで指定する(例: 10.250.0.1)。"
  }
}

variable "local_as" {
  description = "このノードの AS 番号(bao-02 は 65041、bao-03 は 65042)。Inuyama の AS(inuyama_asn)とも、既存の AS とも衝突させない"
  type        = number

  validation {
    condition     = var.local_as >= 1 && var.local_as <= 4294967294
    error_message = "local_as は 1 から 4294967294 の範囲にすること。"
  }
}

variable "remote_as" {
  description = "neighbor の AS 番号。Inuyama の control-plane は local-as(inuyama_asn、65010)を名乗るので、これに合わせる"
  type        = number
}

variable "neighbors" {
  description = "eBGP の neighbor の IPv4 アドレス(overlay 上の Inuyama の control-plane。例: 10.250.0.11/12/13)"
  type        = list(string)

  validation {
    condition     = length(var.neighbors) > 0 && alltrue([for n in var.neighbors : can(cidrhost("${n}/32", 0))])
    error_message = "neighbors は 1 つ以上の IPv4 アドレス(CIDR なし)にすること。"
  }
}

variable "import_prefixes" {
  description = "受け取る prefix(完全一致)。これ以外は捨てる。既定は、Inuyama の 10.0.0.0/24(クラスタ LAN)と 192.168.1.0/24(worker の LAN)"
  type        = list(string)
  default     = ["10.0.0.0/24", "192.168.1.0/24"]

  validation {
    condition     = alltrue([for p in var.import_prefixes : can(cidrhost(p, 0))])
    error_message = "import_prefixes は 10.0.0.0/24 のような CIDR の形式にすること。"
  }
}
