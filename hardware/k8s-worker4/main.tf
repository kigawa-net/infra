# k8s-worker4(192.168.1.121)。kubeadm join などの既存の構築は、このモジュールの対象外(手動で構築済み)。
# 2026-10-05 から、node-dns(内部ドメインを kresd に向ける)のみを、IaC で管理する。

data "external" "ssh_key" {
  program = ["bash", "-c", <<-EOT
    source "${path.module}/../../lib/bws-retry.sh"
    value=$(bws_get_value "${var.control_plane_ssh_key_bitwarden_id}") || exit 1
    # bwsが503等で空/nullを返すと、空の値のまま後続のSSH/sudoに進んでしまう
    # (2026-10-03のionos障害と同じ構造)。空ならエラーにしてplan/applyを止める。
    if [ -z "$value" ] || [ "$value" = "null" ]; then
      echo "ssh_key: bws secret is empty" >&2
      exit 1
    fi
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

data "external" "sudo_password" {
  program = ["bash", "-c", <<-EOT
    source "${path.module}/../../lib/bws-retry.sh"
    value=$(bws_get_value "${var.sudo_password_bitwarden_id}") || exit 1
    # bwsが503等で空/nullを返すと、空の値のまま後続のSSH/sudoに進んでしまう
    # (2026-10-03のionos障害と同じ構造)。空ならエラーにしてplan/applyを止める。
    if [ -z "$value" ] || [ "$value" = "null" ]; then
      echo "sudo_password: bws secret is empty" >&2
      exit 1
    fi
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

# workerノードから内部ネットワーク(10.0.0.0/24)への静的経路と、1 分ごとの再適用タイマー(issue #193 / #198)。
# worker4 は手動で経路を入れていた(cluster-route.service は 1 回実行されるだけ)ため、経路が消えると自動では
# 戻らなかった。2026-10-16 に、worker4 だけ 10.0.0.0/24 の経路が無く(default の 192.168.1.1 に出て届かない)、
# 同じ worker4 に載った CoreDNS の 10.0.0.53 向け forward が失敗し、kivra のログインが落ちた。
# k8s-worker3 / k8s-worker5 と同じ構成にする。既存の /usr/local/bin/cluster-route.sh と同じ内容を入れ直すだけ。
module "cluster_route" {
  source = "../modules/cluster-route"

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value
  # Core Router VIP(#241)1 本(docs/network.md の 2.5 節)。
  gateways = [var.core_router_vip]
  # EasyTier のオーバーレイ(10.250.0.0/24)。Inuyama の Pod から bao-02/03 へ届けるため(control-plane の tun が出口になる)
  extra_destination_cidrs = ["10.250.0.0/24"]
}

# 内部ドメイン(kigawa.net など)を、kresd に向ける。ノードは、自宅ルーターで k8s.kigawa.net を引いており、
# ルーターの上流(k8s2)が止まると、kubelet が API に繋がらなくなった(2026-10-04)。
module "node_dns" {
  source = "../modules/node-dns"

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value
}

# journald の上限(/run の ramdisk 圧迫対策、k8s-system#259)。
# k8s1/k8s2/k8s4/k8s-worker5 には適用済みだが、この3台には未適用だった。
# worker3 は 2026-10-05 時点で /run の tmpfs 6.3G に対し 6.2G 使用(98
# journald の上限(/run の ramdisk 圧迫対策、k8s-system#259)。
# k8s1/k8s2/k8s4/k8s-worker5 には適用済みだが、この3台には未適用だった。
# worker3 は 2026-10-05 時点で /run の tmpfs 6.3G に対し 6.2G 使用(98%)で
# DiskPressure が発生していた(infra#243 参照)。journald は既定で
# ファイルシステムの 10%(最大 4GB)まで log を ramdisk に書けるため、
# 小さな tmpfs を持つノードでは他の用途(sandbox/shm)を圧迫する。
module "journald_limit" {
  source = "../modules/journald-limit"

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value
}
