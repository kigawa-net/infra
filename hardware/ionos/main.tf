locals {
  haproxy_enabled = var.inuyama_ingress_vip != "" || var.minecraft_backend_vip != ""

  inuyama_prefix_list_rules = concat(
    [for index, prefix in var.inuyama_accepted_prefixes : format("ip prefix-list INUYAMA-IN seq %d permit %s", (index + 1) * 10, prefix)],
    ["ip prefix-list INUYAMA-IN seq 999 deny 0.0.0.0/0 le 32"],
  )
  ionos_prefix_list_rules = concat(
    [for index, prefix in var.ionos_advertised_prefixes : format("ip prefix-list IONOS-OUT seq %d permit %s", (index + 1) * 10, prefix)],
    # Soichiro から学習した管理 IP(/32)を Inuyama(k8s4)へ再広告する。`network` 文は出さない
    # (IONOS 自身が発生源ではなく、BGP で学習した経路を中継するだけのため)。
    var.soichiro_wireguard_public_key != "" ? [for index, prefix in var.soichiro_accepted_prefixes : format("ip prefix-list IONOS-OUT seq %d permit %s", 500 + (index + 1) * 10, prefix)] : [],
    ["ip prefix-list IONOS-OUT seq 999 deny 0.0.0.0/0 le 32"],
  )

  # Soichiro 専用の prefix-list。Soichiro からは管理 IP の /32 だけを受け取り、
  # Soichiro へは Inuyama のネットワーク(inuyama_accepted_prefixes)だけを渡す。
  soichiro_prefix_list_rules = concat(
    [for index, prefix in var.soichiro_accepted_prefixes : format("ip prefix-list SOICHIRO-IN seq %d permit %s", (index + 1) * 10, prefix)],
    ["ip prefix-list SOICHIRO-IN seq 999 deny 0.0.0.0/0 le 32"],
    [for index, prefix in var.inuyama_accepted_prefixes : format("ip prefix-list SOICHIRO-OUT seq %d permit %s", (index + 1) * 10, prefix)],
    ["ip prefix-list SOICHIRO-OUT seq 999 deny 0.0.0.0/0 le 32"],
  )
  ionos_network_statements = concat(
    [for prefix in var.ionos_advertised_prefixes : "  network ${prefix}"],
    # k8s4(Inuyama)は、IONOS が許可する 10.0.0.0/24 を BGP で渡さない(k8s4 の export は 10.0.0.0/16 の完全一致)ため、
    # IONOS の BGP テーブルには Inuyama のネットワークが無く、Soichiro に渡せない。
    # IONOS 自身が持つカーネル経路(10.0.0.0/24 dev wg0、WireGuard の AllowedIPs 由来)を、Soichiro 向けにだけ発生させる。
    # IONOS-OUT(Inuyama / Oracle 向け)は 10.0.0.0/24 を許可しないので、他のピアには漏れない。
    var.soichiro_wireguard_public_key != "" ? [for prefix in var.inuyama_accepted_prefixes : "  network ${prefix}"] : [],
  )

  k8s_wireguard_peers = concat(
    var.k8s1_wireguard_public_key != "" ? [{
      public_key           = var.k8s1_wireguard_public_key
      allowed_ips          = ["${var.k8s1_wireguard_address}/32"]
      endpoint             = ""
      persistent_keepalive = var.wireguard_persistent_keepalive
    }] : [],
    # 【重要】k8s2に10.0.0.0/24を割り当てるとk8s4のピアエントリ
    # (下記、同じ10.0.0.0/24を保持)と重複し、WireGuardの暗号鍵ルーティング
    # テーブル(cryptokey routing table)は同一プレフィックスを複数ピアに
    # 割り当てられないため、後から設定されたピアが優先されてしまう。
    # これによりk8s4からの10.0.0.x送信元パケットが送信元スプーフィング
    # チェックで拒否され、soichiro等への中継が全滅する実害が発生した
    # (issue #121で発見)。k8s2はBGP制御プレーンの冗長化(eBGPセッション
    # 確立)のみを目的とし、データプレーンの中継(10.0.0.0/24)はk8s4が
    # 引き続き専有する。真のデータプレーン冗長化には動的な切り替え機構が
    # 別途必要。
    var.k8s2_wireguard_public_key != "" ? [{
      public_key           = var.k8s2_wireguard_public_key
      allowed_ips          = ["${var.k8s2_wireguard_address}/32"]
      endpoint             = ""
      persistent_keepalive = var.wireguard_persistent_keepalive
    }] : [],
    # OneServerMC/infra の GitHub Actions(ubuntu-latest)が hardware/soichiro の
    # terraform apply 時に k8s1 へ到達する(kubeadm join token取得)ための静的ピア。
    # ephemeralなrunnerでSSH公開鍵を都度取得できないため、事前生成した固定鍵を使う。
    [{
      public_key           = var.ci_runner_wireguard_public_key
      allowed_ips          = ["${var.ci_runner_wireguard_address}/32"]
      endpoint             = ""
      persistent_keepalive = var.wireguard_persistent_keepalive
    }],
    # kigawa-net/infra自身のGitHub Actions(ubuntu-latest)が terraform apply
    # 実行時にk8s1/k8s2/k8s4等(プライベートIP)へ到達するための静的ピア。
    # OneServerMC/infra用のci_runner_wireguard_*とは別の専用ピア。
    [{
      public_key           = var.kigawa_infra_ci_runner_wireguard_public_key
      allowed_ips          = ["${var.kigawa_infra_ci_runner_wireguard_address}/32"]
      endpoint             = ""
      persistent_keepalive = var.wireguard_persistent_keepalive
    }],
    # kigawa-net-k8s のPR CI(GitHub-hosted ubuntu-latest)がWireGuardトンネル経由で
    # k8s.kigawa.net(10.0.0.100:6443)へ接続するための静的ピア。他のCI用ピアとは別の専用ピア。
    [{
      public_key           = var.kigawa_net_k8s_ci_runner_wireguard_public_key
      allowed_ips          = ["${var.kigawa_net_k8s_ci_runner_wireguard_address}/32"]
      endpoint             = ""
      persistent_keepalive = var.wireguard_persistent_keepalive
    }],
    # Oracle Cloud(バックアップハブ)。Inuyama<->IONOS間のリンクが落ちた場合の
    # 迂回経路として、IONOS<->Oracle間を直接接続する。OracleはIONOSと同じく
    # 固定IPを持つゲートウェイのため、AllowedIPsにOracle自身のトンネルIPだけでなく
    # ホームサブネット(172.31.253.0/24)も含め、Oracle経由の中継を可能にする
    # (var.wireguard_peer_allowed_ipsでInuyama向けピアに10.0.0.0/24を含めているのと
    # 同じ考え方)。IONOS側からOracleへダイヤルする(Oracleは固定パブリックIPを持つ)。
    var.oracle_wireguard_public_key != "" ? [{
      public_key           = var.oracle_wireguard_public_key
      allowed_ips          = ["${var.oracle_wireguard_address}/32", var.oracle_home_subnet]
      endpoint             = var.oracle_wireguard_endpoint
      persistent_keepalive = var.wireguard_persistent_keepalive
    }] : [],
    # Soichiro(Karmada の etcd #2 / control plane)。Soichiro 側から IONOS へ発信する(endpoint なし)。
    # 公開鍵は静的な値。AllowedIPs は、トンネル内 IP と、管理 IP(/32)だけ(他のピアと重複させない。issue #121)。
    var.soichiro_wireguard_public_key != "" ? [{
      public_key           = var.soichiro_wireguard_public_key
      allowed_ips          = concat(["${var.soichiro_wireguard_address}/32"], var.soichiro_accepted_prefixes)
      endpoint             = ""
      persistent_keepalive = var.wireguard_persistent_keepalive
    }] : [],
  )

  # k8s4(inuyama)は唯一のeBGPゲートウェイで単一障害点だったため、k8s2にも
  # 同じAS(inuyama_asn)で2本目のeBGPセッションを張り、冗長化する。
  gateway_bgp_peers = concat(
    [{
      wg_address = var.inuyama_wireguard_address
      asn        = var.inuyama_asn
      in_list    = "INUYAMA-IN"
      out_list   = "IONOS-OUT"
    }],
    var.k8s2_wireguard_public_key != "" ? [{
      wg_address = var.k8s2_wireguard_address
      asn        = var.inuyama_asn
      in_list    = "INUYAMA-IN"
      out_list   = "IONOS-OUT"
    }] : [],
    # Oracle Cloud(バックアップハブ、AS65040)。IONOS-OUT/INUYAMA-INの既存
    # prefix-listがそのまま適用されるため、IONOSは172.31.254.0/24をOracleへ
    # 広告し、Oracle経由で学習した10.0.0.0/24(Inuyama<->Oracle間で既に確立
    # 済みのeBGPセッション経由で学習されたもの)を受け入れる、という迂回経路が
    # 自動的に構成される。
    var.oracle_wireguard_public_key != "" ? [{
      wg_address = var.oracle_wireguard_address
      asn        = var.oracle_asn
      in_list    = "INUYAMA-IN"
      out_list   = "IONOS-OUT"
    }] : [],
    # Soichiro(AS65040とは別、AS65020)。専用の prefix-list を使う(管理 IP の /32 だけを受け取る)。
    var.soichiro_wireguard_public_key != "" ? [{
      wg_address = var.soichiro_wireguard_address
      asn        = var.soichiro_asn
      in_list    = "SOICHIRO-IN"
      out_list   = "SOICHIRO-OUT"
    }] : [],
  )

  wireguard_config = templatefile("${path.module}/templates/wg0.conf.tpl", {
    address     = var.wireguard_address
    listen_port = var.wireguard_listen_port
    mtu         = var.wireguard_mtu
    peers = concat([{
      public_key           = data.external.inuyama_wireguard_public_key.result.value
      allowed_ips          = var.wireguard_peer_allowed_ips
      endpoint             = var.inuyama_wireguard_endpoint
      persistent_keepalive = var.wireguard_persistent_keepalive
    }], local.k8s_wireguard_peers)
  })

  frr_config = templatefile("${path.module}/templates/frr.conf.tpl", {
    hostname                 = var.hostname
    ionos_asn                = var.ionos_asn
    bgp_router_id            = var.bgp_router_id
    gateway_bgp_peers        = local.gateway_bgp_peers
    wireguard_interface      = var.wireguard_interface
    inuyama_prefix_list      = join("\n", local.inuyama_prefix_list_rules)
    ionos_prefix_list        = join("\n", local.ionos_prefix_list_rules)
    soichiro_prefix_list     = var.soichiro_wireguard_public_key != "" ? join("\n", local.soichiro_prefix_list_rules) : ""
    ionos_network_statements = join("\n", local.ionos_network_statements)
  })

  haproxy_config = templatefile("${path.module}/templates/haproxy.cfg.tpl", {
    inuyama_ingress_vip   = var.inuyama_ingress_vip
    minecraft_backend_vip = var.minecraft_backend_vip
  })

  # このスクリプト自体の内容をtriggersでハッシュ追跡できるよう、
  # provisioner内に直接書かず独立したlocalとして定義する
  # (直接書くと内容を変更してもtriggersが変化せず再適用されない)。
  setup_script = <<-SCRIPT
    #!/bin/bash
    set -eo pipefail
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    umask 077
    exec > >(tee -a /tmp/ionos-gateway-setup.log) 2>&1

    case "${var.wireguard_interface}" in
      ""|*[!a-zA-Z0-9._-]*)
        echo "wireguard_interface contains unsupported characters"
        exit 1
        ;;
    esac

    haproxy_enabled="${local.haproxy_enabled}"
    manage_firewall="${var.manage_firewall}"

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y ca-certificates frr haproxy iproute2 iptables prometheus-node-exporter ufw wireguard

    install -d -m 700 /etc/wireguard

    if [ ! -f /etc/wireguard/ionos_private.key ]; then
      wg genkey > /etc/wireguard/ionos_private.key
      wg pubkey < /etc/wireguard/ionos_private.key > /etc/wireguard/ionos_public.key
    fi

    chmod 600 /etc/wireguard/ionos_private.key
    ionos_private_key=$(cat /etc/wireguard/ionos_private.key)

    sed "s|__IONOS_PRIVATE_KEY__|$ionos_private_key|g" /tmp/ionos-wg0.conf.tpl > /etc/wireguard/${var.wireguard_interface}.conf
    chmod 600 /etc/wireguard/${var.wireguard_interface}.conf

    cat > /etc/sysctl.d/99-ionos-gateway.conf <<SYSCTL
    net.ipv4.ip_forward = 1
    SYSCTL
    sysctl --system

    install -d -m 755 /etc/systemd/system/frr.service.d
    cat > /etc/systemd/system/frr.service.d/ionos-gateway.conf <<UNIT
    [Unit]
    After=network-online.target wg-quick@${var.wireguard_interface}.service
    Wants=network-online.target wg-quick@${var.wireguard_interface}.service
    UNIT

    install -d -m 755 /etc/systemd/system/haproxy.service.d
    cat > /etc/systemd/system/haproxy.service.d/ionos-gateway.conf <<UNIT
    [Unit]
    After=network-online.target wg-quick@${var.wireguard_interface}.service
    Wants=network-online.target wg-quick@${var.wireguard_interface}.service
    UNIT

    systemctl daemon-reload
    systemctl enable wg-quick@${var.wireguard_interface}
    systemctl restart wg-quick@${var.wireguard_interface}

    install -m 640 -o frr -g frr /tmp/ionos-frr.conf /etc/frr/frr.conf
    sed -i 's/^zebra=.*/zebra=yes/' /etc/frr/daemons
    sed -i 's/^bgpd=.*/bgpd=yes/' /etc/frr/daemons
    systemctl enable frr
    systemctl restart frr

    install -m 644 /tmp/ionos-haproxy.cfg /etc/haproxy/haproxy.cfg
    if [ "$haproxy_enabled" = "true" ]; then
      haproxy -c -f /etc/haproxy/haproxy.cfg
      systemctl enable haproxy
      systemctl restart haproxy
    else
      systemctl disable --now haproxy || true
    fi

    if [ "$manage_firewall" = "true" ]; then
      ufw allow ${var.firewall_ssh_port}/tcp
      ufw allow 80/tcp
      ufw allow 443/tcp
      ufw allow 25565/tcp
      ufw allow ${var.wireguard_listen_port}/udp
      # eBGPゲートウェイ(inuyama/k8s4、および冗長化用のk8s2)からの
      # BGP(179)・node-exporter(9100)接続を許可する。k8s2用のルールが
      # 無いと、k8s2からのBGP接続(TCP SYN)がUFWのdefault-denyで
      # 暗黙にドロップされ、external0セッションがIdleのまま進まない
      # 問題が起きる。
      %{for peer in local.gateway_bgp_peers~}
      ufw allow in on ${var.wireguard_interface} from ${peer.wg_address} to any port 179 proto tcp
      ufw allow in on ${var.wireguard_interface} from ${peer.wg_address} to any port 9100 proto tcp
      %{endfor~}
      # UFWのデフォルトforward(routed)ポリシーはDROPのため、ip_forward=1と
      # BGP/ルーティングが正しくてもWireGuardピア間の中継(soichiro/CI runner等の
      # クライアントからk8s4(inuyama)経由でクラスタLANへの通信)がずっと
      # 暗黙にブロックされていた。wg0インターフェース間の転送を明示的に許可する。
      ufw route allow in on ${var.wireguard_interface} out on ${var.wireguard_interface}
      # Karmada の etcd #3(2379/2380)。下の `deny 2379:2380/tcp`(公開インターネット向け)より前に、
      # WireGuard 内の特定の送信元だけを許可する。ufw は順序で評価するため、`insert 1` で先頭に入れる
      # (すでに同じルールがあれば、スキップされる)。
      %{for src in var.etcd_allowed_sources~}
      ufw insert 1 allow in on ${var.wireguard_interface} from ${src} to any port 2379,2380 proto tcp
      %{endfor~}
      ufw deny 179/tcp
      ufw deny 6443/tcp
      ufw deny 2379:2380/tcp
      ufw deny 10250/tcp
      ufw --force enable
    fi

    systemctl enable prometheus-node-exporter
    systemctl restart prometheus-node-exporter

    wg show ${var.wireguard_interface}
    vtysh -c 'show bgp summary' || true
  SCRIPT
}

data "external" "ssh_key" {
  program = ["bash", "-c", <<-EOT
    source "${path.module}/../../lib/bws-retry.sh"
    value=$(bws_get_value "${var.ssh_key_bitwarden_id}") || exit 1
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

data "external" "sudo_password" {
  program = ["bash", "-c", <<-EOT
    source "${path.module}/../../lib/bws-retry.sh"
    value=$(bws_get_value "${var.sudo_password_bitwarden_id}") || exit 1
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

data "external" "inuyama_wireguard_public_key" {
  program = ["bash", "-c", <<-EOT
    source "${path.module}/../../lib/bws-retry.sh"
    value=$(bws_get_value "${var.inuyama_wireguard_public_key_bitwarden_id}") || exit 1
    # 2026-10-03: bwsが空を返すと「PublicKey =」が空のwg0.confが生成され、wg-quick@wg0が
    # 起動できずionosゲートウェイが約1.5時間停止した。空/null/異常な値は必ずエラーにして
    # applyを止める(WireGuard公開鍵は44文字のbase64)。
    if [ -z "$value" ] || [ "$value" = "null" ] || ! printf '%s' "$value" | grep -Eq '^[A-Za-z0-9+/]{43}=$'; then
      echo "inuyama_wireguard_public_key is empty or not a WireGuard public key" >&2
      exit 1
    fi
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

resource "null_resource" "ionos_gateway" {
  triggers = {
    setup_version                  = "3"
    host                           = var.host
    inuyama_wireguard_publickey_id = var.inuyama_wireguard_public_key_bitwarden_id
    inuyama_wireguard_publickey    = sha256(data.external.inuyama_wireguard_public_key.result.value)
    wireguard_config               = sha256(local.wireguard_config)
    k8s1_wireguard_public_key      = sha256(var.k8s1_wireguard_public_key)
    k8s2_wireguard_public_key      = sha256(var.k8s2_wireguard_public_key)
    frr_config                     = sha256(local.frr_config)
    haproxy_config                 = sha256(local.haproxy_config)
    setup_script                   = sha256(local.setup_script)
    firewall                       = tostring(var.manage_firewall)
    haproxy_enabled                = tostring(local.haproxy_enabled)
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = data.external.ssh_key.result.value
  }

  provisioner "file" {
    content     = local.wireguard_config
    destination = "/tmp/ionos-wg0.conf.tpl"
  }

  provisioner "file" {
    content     = local.frr_config
    destination = "/tmp/ionos-frr.conf"
  }

  provisioner "file" {
    content     = local.haproxy_config
    destination = "/tmp/ionos-haproxy.cfg"
  }

  provisioner "file" {
    content     = local.setup_script
    destination = "/tmp/ionos-gateway-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "if [ \"$(id -u)\" -eq 0 ]; then bash /tmp/ionos-gateway-setup.sh && rm -f /tmp/ionos-gateway-setup.sh /tmp/ionos-wg0.conf.tpl /tmp/ionos-frr.conf /tmp/ionos-haproxy.cfg; else echo '${data.external.sudo_password.result.value}' | sudo -S bash /tmp/ionos-gateway-setup.sh && rm -f /tmp/ionos-gateway-setup.sh /tmp/ionos-wg0.conf.tpl /tmp/ionos-frr.conf /tmp/ionos-haproxy.cfg; fi",
    ]
  }
}
