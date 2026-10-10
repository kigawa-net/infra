variable "host" {
  type = string
}

variable "ssh_user" {
  description = "root であること(etcd のインストール・systemd・秘密鍵の読み取りに必要。sudo のパスワードは、この module では扱わない)"
  type        = string
  default     = "root"

  validation {
    condition     = var.ssh_user == "root"
    error_message = "ssh_user は root にすること。"
  }
}

variable "ssh_private_key" {
  type      = string
  sensitive = true
}

variable "member_name" {
  description = "etcd のメンバー名"
  type        = string
  default     = "ionos"
}

variable "advertise_address" {
  description = "このメンバーが、client / peer で待ち受け・広告するアドレス(WireGuard のアドレス)。証明書の SAN に含まれていること"
  type        = string
  default     = "172.31.254.2"
}

variable "join" {
  description = <<-DESC
    true にすると、既存のクラスターに learner として参加する(`member add --learner`)。false の間は、バイナリ・ユニット・環境ファイルの用意だけで、参加も起動もしない。
    参加の前提: (1) クラスターの learner の数が、上限(--max-learners、既定 1)に達していないこと。すでに別の learner(Soichiro)がいるなら、
    上限を上げる(既存のメンバーの再起動が要る)か、先にその learner を promote する。(2) 証明書が置かれていること。
    quorum への影響は、kigawa-net-k8s#272 を参照。
  DESC
  type        = bool
  default     = false
}

variable "seed_endpoints" {
  description = "参加するときに接続する、既存のメンバーの client エンドポイント(カンマ区切り)"
  type        = string
  default     = "https://10.0.0.243:2379"
}

variable "initial_cluster_token" {
  type    = string
  default = "karmada-etcd-prod"
}

variable "etcd_version" {
  description = "etcd のバージョン。クラスターの他のメンバーと同じにすること"
  type        = string
  default     = "3.6.8"
}

variable "etcd_tarball_sha256" {
  description = "etcd-v<etcd_version>-linux-amd64.tar.gz の SHA256(公式の SHA256SUMS と照合してピン留めする)"
  type        = string
  default     = "cf9cfe91a4856cb90eed9c99e6aee4b708db2c7888b88a6f116281f04b0ea693"
}

variable "heartbeat_interval_ms" {
  description = "全メンバーで同一の値にすること(kigawa-net-k8s#269)"
  type        = number
  default     = 500
}

variable "election_timeout_ms" {
  description = "全メンバーで同一の値にすること(kigawa-net-k8s#269)"
  type        = number
  default     = 5000
}

variable "quota_backend_bytes" {
  type    = number
  default = 4294967296
}

variable "memory_high" {
  description = "systemd の MemoryHigh。IONOS はメモリ 1.8GB で、WireGuard / FRR / HAProxy も載っているため、上限を設ける"
  type        = string
  default     = "600M"
}

variable "memory_max" {
  description = "systemd の MemoryMax"
  type        = string
  default     = "800M"
}

variable "peer_skip_client_san_verification" {
  description = "peer の client 証明書の SAN と、接続元 IP の照合を外す(暫定。Inuyama の etcd と揃える。kigawa-net-k8s#272 の案 A。根本案 B に移したら false にする)"
  type        = bool
  default     = true
}
