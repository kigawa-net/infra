variable "host" {
  type = string
}

variable "ssh_user" {
  description = "root であること(バイナリの配置・systemd・iptables・ufw に必要。sudo のパスワードは、この module では扱わない)"
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

variable "stage" {
  description = <<-DESC
    段階的な有効化。
      prepare   : バイナリ・ユニット・slice・/etc/hosts・REDIRECT・ufw の許可を用意する。**何も起動しない**(起動中のものは止める = ロールバック)
      apiserver : kube-apiserver だけを起動する(etcd の 3 メンバーに接続でき、/readyz が通ること)
      full      : kube-apiserver と、残りのコンポーネントを起動する
    証明書(/etc/karmada/pki/)は、この IaC の外で用意する。apiserver 以降の段階では、必要なファイルが揃っていないと、起動せずに中止する。
  DESC
  type        = string
  default     = "prepare"

  validation {
    condition     = contains(["prepare", "apiserver", "full"], var.stage)
    error_message = "stage は prepare / apiserver / full のどれか。"
  }
}

variable "advertise_address" {
  description = "kube-apiserver が待ち受ける、WireGuard のアドレス(公開 IP では待ち受けない)。apiserver の証明書の SAN に含まれていること"
  type        = string
  default     = "172.31.254.2"

  validation {
    condition     = can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.advertise_address))
    error_message = "advertise_address は IPv4 アドレスにすること。"
  }
}

variable "etcd_servers" {
  description = "kube-apiserver / aggregated-apiserver が接続する etcd(ローカルのメンバーを先頭に)"
  type        = list(string)
  default = [
    "https://172.31.254.2:2379",
    "https://10.0.0.243:2379",
    "https://10.255.10.12:2379",
  ]
}

variable "api_allowed_sources" {
  description = "kube-apiserver(5443/tcp)に、WireGuard(wg)内から接続してよい送信元。ufw の許可を、wg インターフェースに限って追加する"
  type        = list(string)
  default     = ["172.31.254.1", "192.168.1.130"]

  validation {
    condition     = alltrue([for s in var.api_allowed_sources : can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", s))])
    error_message = "api_allowed_sources は IPv4 アドレスのリストにすること。"
  }
}

variable "wireguard_interface" {
  type    = string
  default = "wg0"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]{1,15}$", var.wireguard_interface))
    error_message = "wireguard_interface は、英数字・_・.・- の 15 文字以内にすること。"
  }
}

variable "service_cluster_ip_range" {
  description = "Inuyama の apiserver と同じ値にすること(全 control plane で揃える)"
  type        = string
  default     = "10.96.0.0/12"
}

variable "enable_kube_controller_manager" {
  description = <<-DESC
    kube-controller-manager を、この host で動かすか。**既定は false**。
    Inuyama の kube-controller-manager は、CSR の署名(csrsigning)のために、apiserver の CA の**秘密鍵**(ca.key)を使っている。
    IONOS は、全拠点のハブで、公開 IP を持つため、CA の秘密鍵を置かない。また、leader election で動くため、鍵の無いインスタンスが leader になると、
    クラスター全体で CSR の署名が止まる。Inuyama の 2 レプリカで足りるため、動かさない。
  DESC
  type        = bool
  default     = false
}

variable "cp_memory_high" {
  description = "karmada-cp.slice の MemoryHigh。IONOS はメモリ 1.8GB で swap が無く、ゲートウェイ(WireGuard / FRR / HAProxy)と etcd が同居する。超えると、CP のサービスだけが絞られる"
  type        = string
  default     = "650M"
}

variable "cp_memory_max" {
  description = "karmada-cp.slice の MemoryMax(上限)。超えると、CP のサービスだけが OOM で止まる(ゲートウェイは巻き込まない)"
  type        = string
  default     = "800M"
}

variable "karmada_key_fingerprint" {
  description = <<-DESC
    karmada.key(管理者権限の鍵。人の手で配置する)の、公開鍵の指紋(SHA-256、DER)。公開してよい情報。
    起動の前に、配置された鍵の指紋と照合して、転送の途中の破損・すり替えを検出する。空にすると、照合しない。
    (2026-10-10 に、対になる証明書 karmada.crt の公開部分から、独立に計算した値)
  DESC
  type        = string
  default     = "2da3dd8a18530258a91ebe2bb350b6f0028bc6027e28b939af48cb1f43bca4ef"

  validation {
    condition     = var.karmada_key_fingerprint == "" || can(regex("^[0-9a-f]{64}$", var.karmada_key_fingerprint))
    error_message = "karmada_key_fingerprint は、空、または 64 桁の 16 進数にすること。"
  }
}

variable "min_available_memory_mb" {
  description = "起動の前に、MemAvailable がこの値(MB)以上あることを確認する。足りなければ、起動せずに中止する"
  type        = number
  default     = 700
}

# --- バイナリ(取得元と SHA256 を、ピン留めする) ---------------------------------

variable "kubernetes_version" {
  type    = string
  default = "1.36.2"
}

variable "binaries" {
  description = <<-DESC
    配置するバイナリ。sha256 は、取得後のバイナリの SHA256(一致しなければ、配置しない)。
      source = "url"   : url から取得(kube-apiserver / kube-controller-manager。公式の .sha256 と照合済み)
      source = "image" : コンテナ image(digest 指定)から、crane で取り出す(Karmada のコンポーネント。リリースにバイナリが無いため)
  DESC
  type = map(object({
    source = string
    ref    = string               # url、または image@sha256:digest
    path   = optional(string, "") # image 内のパス
    sha256 = string
  }))
  default = {
    "kube-apiserver" = {
      source = "url"
      ref    = "https://dl.k8s.io/release/v1.36.2/bin/linux/amd64/kube-apiserver"
      sha256 = "6770be17296ef36b656ad84e52b043007fb9a47ba0445c224097323291b1b33b"
    }
    "kube-controller-manager" = {
      source = "url"
      ref    = "https://dl.k8s.io/release/v1.36.2/bin/linux/amd64/kube-controller-manager"
      sha256 = "6332e45474baf6362f50394d8f7c6002274db04d68fe51dbe2229ef5c0b21e3c"
    }
    "karmada-controller-manager" = {
      source = "image"
      ref    = "docker.io/karmada/karmada-controller-manager@sha256:228ea9511b9f971f000cfdef05962c09c7570ea4b6054fce652b0cbb00873a4b"
      path   = "bin/karmada-controller-manager"
      sha256 = "d1104e17c054fb340a408ca49a9112160ac2e1f3df8fbce23e5729b5fa6590af"
    }
    "karmada-scheduler" = {
      source = "image"
      ref    = "docker.io/karmada/karmada-scheduler@sha256:1aed7d9b1e8501b8d496cf32a624211f212a23f47c3c5d4ae5463de42bbd5c2a"
      path   = "bin/karmada-scheduler"
      sha256 = "90c017c59b4a80e1bf8f8c554550314040f72c3277667cbc0a6552bdd96e917f"
    }
    "karmada-webhook" = {
      source = "image"
      ref    = "docker.io/karmada/karmada-webhook@sha256:22e821d7a694c460713093461aedb13691eb29471f77cbde27ef6e0dc3a7bb18"
      path   = "bin/karmada-webhook"
      sha256 = "4e74818d095a7069caa99b4d6352ea7151fa017b498e8f6d4a67c47637380bb3"
    }
    "karmada-aggregated-apiserver" = {
      source = "image"
      ref    = "docker.io/karmada/karmada-aggregated-apiserver@sha256:e15281b3e72a4d31076453bc197b55f57234525d79f41e39a8e62a6f6e8d66c7"
      path   = "bin/karmada-aggregated-apiserver"
      sha256 = "99113de3de27d5c476f69498a60b6f71780bff99da1ba83e573325fed53c6c67"
    }
    "karmada-metrics-adapter" = {
      source = "image"
      ref    = "docker.io/karmada/karmada-metrics-adapter@sha256:1da93364e76e06b26854d5cb3b12bac9ee915700beec92188a7886e4e4088804"
      path   = "bin/karmada-metrics-adapter"
      sha256 = "0cd7e759ead1e85f89bdad0774689d7120d99c1882984ef809528ae90021d321"
    }
  }

  validation {
    condition     = alltrue([for k, b in var.binaries : contains(["url", "image"], b.source) && can(regex("^[0-9a-f]{64}$", b.sha256))])
    error_message = "source は url / image、sha256 は 64 桁の 16 進数にすること。"
  }

  validation {
    condition = alltrue([
      for k, b in var.binaries : can(regex("^(kube|karmada)-[a-z-]+$", k)) &&
      (b.source != "image" || (can(regex("^[A-Za-z0-9._/-]+$", b.path)) && !startswith(b.path, "/") && !strcontains(b.path, "..")))
    ])
    error_message = "バイナリ名は kube-* / karmada-*、image 内の path は相対パスで .. を含まないこと。"
  }
}

variable "crane" {
  description = "image からバイナリを取り出す道具(単一の静的バイナリ。公式の checksums.txt と一致を確認した SHA256 でピン留め)"
  type = object({
    url    = string
    sha256 = string # tarball の SHA256
  })
  default = {
    url    = "https://github.com/google/go-containerregistry/releases/download/v0.22.1/go-containerregistry_Linux_x86_64.tar.gz"
    sha256 = "0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0"
  }
}
