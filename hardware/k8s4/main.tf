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

data "external" "inuyama_wireguard_private_key" {
  program = ["bash", "-c", <<-EOT
    source "${path.module}/../../lib/bws-retry.sh"
    value=$(bws_get_value "${var.inuyama_wireguard_private_key_bitwarden_id}") || exit 1
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

data "external" "inuyama_wireguard_public_key" {
  program = ["bash", "-c", <<-EOT
    source "${path.module}/../../lib/bws-retry.sh"
    value=$(bws_get_value "${var.inuyama_wireguard_public_key_bitwarden_id}") || exit 1
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

data "external" "join_info" {
  program = ["bash", "-c", <<-EOT
    source "${path.module}/../../lib/bws-retry.sh"
    ssh_key=$(bws_get_value "${var.ssh_key_bitwarden_id}") || exit 1
    sudo_pass=$(bws_get_value "${var.sudo_password_bitwarden_id}") || exit 1
    tmpkey=$(mktemp)
    chmod 600 "$tmpkey"
    printf '%s\n' "$ssh_key" > "$tmpkey"

    ssh \
      -i "$tmpkey" \
      -o StrictHostKeyChecking=no \
      -o BatchMode=yes \
      "${var.control_plane_ssh_user}@${var.control_plane_host}" \
      "echo '$sudo_pass' | sudo -S bash -c 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; cp_host=\$(hostname -s); for dead_ip in ${var.remove_dead_control_plane_ips}; do dead_id=\$(kubectl --kubeconfig=/etc/kubernetes/admin.conf exec -n kube-system etcd-\$cp_host -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key member list 2>/dev/null | grep \$dead_ip | cut -d, -f1 | tr -d \" \"); if [ -n \"\$dead_id\" ]; then for attempt in 1 2 3; do kubectl --kubeconfig=/etc/kubernetes/admin.conf exec -n kube-system etcd-\$cp_host -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key member remove \"\$dead_id\" && break; sleep 3; done; fi; done' 2>&1" >&2 || true

    full_cmd=$(ssh \
      -i "$tmpkey" \
      -o StrictHostKeyChecking=no \
      -o BatchMode=yes \
      "${var.control_plane_ssh_user}@${var.control_plane_host}" \
      "echo '$sudo_pass' | sudo -S bash -c 'cert=\$(kubeadm init phase upload-certs --upload-certs 2>&1 | grep -oE \"[0-9a-f]{64}\"); echo \"\$(kubeadm token create --print-join-command 2>/dev/null) --control-plane --certificate-key \$cert\"' 2>/dev/null")

    rm -f "$tmpkey"

    token=$(printf '%s' "$full_cmd"    | grep -oP '(?<=--token )\S+')
    hash=$(printf '%s' "$full_cmd"     | grep -oP '(?<=--discovery-token-ca-cert-hash )\S+')
    cert_key=$(printf '%s' "$full_cmd" | grep -oP '(?<=--certificate-key )\S+')
    printf '{"token":"%s","ca_cert_hash":"%s","certificate_key":"%s"}' "$token" "$hash" "$cert_key"
  EOT
  ]
}

module "control_plane" {
  source = "../modules/k8s-control-plane"

  host            = var.server_ip
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  k8s_version  = var.k8s_version
  k8s_endpoint = var.k8s_endpoint

  join_token           = data.external.join_info.result.token
  join_ca_cert_hash    = data.external.join_info.result.ca_cert_hash
  join_certificate_key = data.external.join_info.result.certificate_key
}

# aliceは廃止済み(issue #157関連)。以前はこのリソースがalice向けwg0
# トンネル(インターフェース・peer設定・wg-quick起動)一式を担っていたが、
# alice向けの部分は削除した。ただし/etc/wireguard/inuyama_private.key/
# inuyama_public.keyは、ionos向けwg1(null_resource.ionos_wireguard)が
# 共用鍵として引き続き参照しているため、鍵配置ロジック自体は残す。
resource "null_resource" "inuyama_wireguard" {
  depends_on = [module.control_plane]

  triggers = {
    host                  = var.server_ip
    inuyama_public_key    = sha256(data.external.inuyama_wireguard_public_key.result.value)
    private_key_secret_id = var.inuyama_wireguard_private_key_bitwarden_id
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = data.external.ssh_key.result.value
  }

  provisioner "file" {
    content     = data.external.inuyama_wireguard_private_key.result.value
    destination = "/tmp/inuyama-wireguard-private.key"
  }

  provisioner "file" {
    content     = <<-SCRIPT
      #!/bin/bash
      set -eo pipefail
      export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      umask 077
      exec > >(tee -a /tmp/inuyama-wireguard-setup.log) 2>&1

      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -f -y
      apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y ca-certificates wireguard

      install -d -m 700 /etc/wireguard

      derived_public_key=$(wg pubkey < /tmp/inuyama-wireguard-private.key)
      configured_public_key="${data.external.inuyama_wireguard_public_key.result.value}"
      if [ "$derived_public_key" != "$configured_public_key" ]; then
        echo "WireGuard private/public key pair mismatch"
        exit 1
      fi

      install -m 600 /tmp/inuyama-wireguard-private.key /etc/wireguard/inuyama_private.key
      printf '%s\n' "$configured_public_key" > /etc/wireguard/inuyama_public.key
      chmod 600 /etc/wireguard/inuyama_private.key /etc/wireguard/inuyama_public.key

      # alice廃止に伴い、以前このリソースが管理していたalice向けwg0トンネルを
      # 後片付けする(既にwg0が存在しない環境では何もしない)。
      systemctl disable --now wg-quick@wg0 2>/dev/null || true
      rm -f /etc/wireguard/wg0.conf
    SCRIPT
    destination = "/tmp/inuyama-wireguard-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${data.external.sudo_password.result.value}' | sudo -S bash /tmp/inuyama-wireguard-setup.sh && rm -f /tmp/inuyama-wireguard-setup.sh /tmp/inuyama-wireguard-private.key",
    ]
  }
}

# GitHub Actions(ubuntu-latest)がWireGuard(ionos→k8s4)経由でworker3/5へSSHできるよう、
# wg1→自宅LANのforwardを「CIランナー→指定worker宛tcp/22」のみに限定して許可し、
# 復路用に同じ通信だけMASQUERADEする(192.168.1.1のスイッチは172.31.254.0/24への
# 経路を持たないため、送信元NATがないと返信が戻らない)。
# k8s4のufwはinactiveでFORWARDは暗黙ACCEPTのため、専用チェーン末尾のDROPで
# CIランナー発の他のLAN宛通信を明示的に遮断する。
resource "null_resource" "ci_ssh_forward" {
  depends_on = [null_resource.ionos_wireguard]

  triggers = {
    host    = var.server_ip
    wg_if   = var.ionos_wireguard_interface
    lan_if  = var.lan_interface
    ci_addr = var.ci_runner_wireguard_address
    targets = join(",", var.ci_ssh_forward_targets)
    version = "1"
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = data.external.ssh_key.result.value
  }

  provisioner "file" {
    content     = <<-SCRIPT
      #!/bin/bash
      set -eo pipefail
      export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      IPT="iptables -w 5"
      WG_IF="${var.ionos_wireguard_interface}"
      LAN_IF="${var.lan_interface}"
      CI="${var.ci_runner_wireguard_address}"
      CHAIN=CI-WG-SSH

      # 専用チェーンを作り直す(再実行しても重複しない)
      $IPT -N $CHAIN 2>/dev/null || $IPT -F $CHAIN
      %{for t in var.ci_ssh_forward_targets~}
      $IPT -A $CHAIN -d ${t}/32 -p tcp --dport 22 -j ACCEPT
      %{endfor~}
      $IPT -A $CHAIN -j DROP

      # CIランナー発のLAN宛通信は専用チェーンで評価(SSH以外は破棄)
      $IPT -C FORWARD -i $WG_IF -o $LAN_IF -s $CI -d 192.168.1.0/24 -j $CHAIN 2>/dev/null \
        || $IPT -I FORWARD 1 -i $WG_IF -o $LAN_IF -s $CI -d 192.168.1.0/24 -j $CHAIN
      # 復路(確立済みのみ)
      $IPT -C FORWARD -i $LAN_IF -o $WG_IF -s 192.168.1.0/24 -d $CI -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
        || $IPT -I FORWARD 1 -i $LAN_IF -o $WG_IF -s 192.168.1.0/24 -d $CI -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

      # 送信元NAT(許可した宛先のtcp/22のみ)
      %{for t in var.ci_ssh_forward_targets~}
      $IPT -t nat -C POSTROUTING -s $CI/32 -d ${t}/32 -o $LAN_IF -p tcp --dport 22 -j MASQUERADE 2>/dev/null \
        || $IPT -t nat -A POSTROUTING -s $CI/32 -d ${t}/32 -o $LAN_IF -p tcp --dport 22 -j MASQUERADE
      %{endfor~}
    SCRIPT
    destination = "/tmp/ci-ssh-forward.sh"
  }

  provisioner "file" {
    content     = <<-UNIT
      [Unit]
      Description=Allow CI runner SSH to LAN workers via wg1 (forward + MASQUERADE, tcp/22 only)
      After=network-online.target wg-quick@${var.ionos_wireguard_interface}.service
      Wants=network-online.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/local/bin/ci-ssh-forward.sh

      [Install]
      WantedBy=multi-user.target
    UNIT
    destination = "/tmp/ci-ssh-forward.service"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${data.external.sudo_password.result.value}' | sudo -S bash -c 'install -m 755 /tmp/ci-ssh-forward.sh /usr/local/bin/ci-ssh-forward.sh && install -m 644 /tmp/ci-ssh-forward.service /etc/systemd/system/ci-ssh-forward.service && systemctl daemon-reload && systemctl enable ci-ssh-forward.service && systemctl restart ci-ssh-forward.service && rm -f /tmp/ci-ssh-forward.sh /tmp/ci-ssh-forward.service'",
    ]
  }
}

resource "null_resource" "ionos_wireguard" {
  depends_on = [null_resource.inuyama_wireguard]

  triggers = {
    host             = var.server_ip
    interface        = var.ionos_wireguard_interface
    address          = var.ionos_wireguard_address
    ionos_address    = "172.31.254.2"
    ionos_public_key = sha256(var.ionos_wireguard_public_key)
    ionos_endpoint   = var.ionos_wireguard_endpoint
    allowed_ips      = join(",", var.ionos_wireguard_allowed_ips)
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = data.external.ssh_key.result.value
  }

  provisioner "file" {
    content     = <<-SCRIPT
      #!/bin/bash
      set -eo pipefail
      export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      umask 077
      exec > >(tee -a /tmp/ionos-wireguard-setup.log) 2>&1

      case "${var.ionos_wireguard_interface}" in
        ""|*[!a-zA-Z0-9._-]*)
          echo "ionos_wireguard_interface contains unsupported characters"
          exit 1
          ;;
      esac

      # wg0 (alice向け) のセットアップで既に /etc/wireguard/inuyama_private.key が
      # 配置されている前提 (このinuyama鍵をionos向けwg1でも共用する)
      if [ ! -f /etc/wireguard/inuyama_private.key ]; then
        echo "/etc/wireguard/inuyama_private.key not found; inuyama_wireguard (wg0) must be applied first"
        exit 1
      fi
      inuyama_private_key=$(cat /etc/wireguard/inuyama_private.key)

      cat > /etc/wireguard/${var.ionos_wireguard_interface}.conf <<WGCONF
      [Interface]
      Address = ${var.ionos_wireguard_address}
      PrivateKey = $inuyama_private_key
      MTU = ${var.wireguard_mtu}

      [Peer]
      PublicKey = ${var.ionos_wireguard_public_key}
      AllowedIPs = ${join(", ", var.ionos_wireguard_allowed_ips)}
      Endpoint = ${var.ionos_wireguard_endpoint}
      PersistentKeepalive = 25
      WGCONF

      chmod 600 /etc/wireguard/${var.ionos_wireguard_interface}.conf
      systemctl enable wg-quick@${var.ionos_wireguard_interface}
      systemctl restart wg-quick@${var.ionos_wireguard_interface}

      # wg-quickがPeerのAllowedIPs(172.31.254.0/24)から自動生成する
      # OSカーネルルート(dev wg1、on-link、protoタグなし)を明示的に削除する。
      # このルートは無指定メトリック(実質0)でBIRDが計算する正しいBGP学習
      # ルート(via 172.31.254.2 dev wg1 proto bird metric 32)より優先されて
      # しまうため、k8sノード間通信が万一172.31.254.0/24内のアドレスを
      # 経由する事態になった場合に、誤ってこの不正確なon-linkルートで
      # WireGuard経由になってしまうリスクがある(hardware/modules/wireguard
      # のdelete_autogenerated_kernel_routeと同じ対応。k8s4のこのリソースは
      # 共有moduleを使わない独自実装のため、同じ修正がこれまで未適用だった)。
      # k8s4自身の172.31.254.0/30(自身のアドレス帯)はkernelルートとして
      # 別途維持されるため、172.31.254.2への到達性には影響しない。
      %{for cidr in var.ionos_wireguard_allowed_ips~}
      ip route del ${cidr} dev ${var.ionos_wireguard_interface} 2>/dev/null || true
      %{endfor~}

      wg show ${var.ionos_wireguard_interface}
    SCRIPT
    destination = "/tmp/ionos-wireguard-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${data.external.sudo_password.result.value}' | sudo -S bash /tmp/ionos-wireguard-setup.sh && rm -f /tmp/ionos-wireguard-setup.sh",
    ]
  }
}


# Oracle Cloud (計画中のバックアップネットワークハブ) 向け WireGuard トンネル (既定interface: wg-oracle)。
# 外部ランブックで計画されている経路のスキャフォールドであり、Oracle Cloud側のホスト自体の
# プロビジョニングは本リポジトリ/本セッションの外で別途対応中。
# oracle_wireguard_public_key が空文字 "" の間は count=0 となり、このリソースは
# 完全に無効(no-op)のまま — plan/applyしても何も作成・変更されない。
# 実エンドポイント/公開鍵が判明し次第、フォローアップ変更でこれらの変数を上書きすれば有効化される。
resource "null_resource" "oracle_wireguard" {
  count      = var.oracle_wireguard_public_key != "" ? 1 : 0
  depends_on = [null_resource.inuyama_wireguard]

  triggers = {
    host              = var.server_ip
    interface         = var.oracle_wireguard_interface
    address           = var.oracle_wireguard_address
    oracle_public_key = sha256(var.oracle_wireguard_public_key)
    oracle_endpoint   = var.oracle_wireguard_endpoint
    allowed_ips       = join(",", var.oracle_wireguard_allowed_ips)
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = data.external.ssh_key.result.value
  }

  provisioner "file" {
    content     = <<-SCRIPT
      #!/bin/bash
      set -eo pipefail
      export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      umask 077
      exec > >(tee -a /tmp/oracle-wireguard-setup.log) 2>&1

      case "${var.oracle_wireguard_interface}" in
        ""|*[!a-zA-Z0-9._-]*)
          echo "oracle_wireguard_interface contains unsupported characters"
          exit 1
          ;;
      esac

      # wg0 (alice向け、廃止済み) のセットアップで既に /etc/wireguard/inuyama_private.key が
      # 配置されている前提 (このinuyama鍵をoracle向けwg-oracleでも共用する)
      if [ ! -f /etc/wireguard/inuyama_private.key ]; then
        echo "/etc/wireguard/inuyama_private.key not found; inuyama_wireguard must be applied first"
        exit 1
      fi
      inuyama_private_key=$(cat /etc/wireguard/inuyama_private.key)

      cat > /etc/wireguard/${var.oracle_wireguard_interface}.conf <<WGCONF
      [Interface]
      Address = ${var.oracle_wireguard_address}
      PrivateKey = $inuyama_private_key
      MTU = ${var.wireguard_mtu}

      [Peer]
      PublicKey = ${var.oracle_wireguard_public_key}
      AllowedIPs = ${join(", ", var.oracle_wireguard_allowed_ips)}
      Endpoint = ${var.oracle_wireguard_endpoint}
      PersistentKeepalive = 25
      WGCONF

      chmod 600 /etc/wireguard/${var.oracle_wireguard_interface}.conf
      systemctl enable wg-quick@${var.oracle_wireguard_interface}
      systemctl restart wg-quick@${var.oracle_wireguard_interface}
      wg show ${var.oracle_wireguard_interface}
    SCRIPT
    destination = "/tmp/oracle-wireguard-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${data.external.sudo_password.result.value}' | sudo -S bash /tmp/oracle-wireguard-setup.sh && rm -f /tmp/oracle-wireguard-setup.sh",
    ]
  }
}

module "bgp" {
  depends_on = [module.control_plane, null_resource.inuyama_wireguard, null_resource.ionos_wireguard, null_resource.oracle_wireguard]
  source     = "../modules/bgp-bird"

  host            = var.server_ip
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  bgp_router_id   = var.server_ip
  bgp_local_as    = var.bgp_local_as
  bgp_peers       = var.bgp_peers
  advertised_vips = var.dns_vip != "" ? [var.dns_vip] : []
  external_bgp_peers = concat(
    [
      {
        local_ip        = trimsuffix(var.ionos_wireguard_address, "/30")
        local_as        = var.inuyama_asn
        neighbor_ip     = "172.31.254.2"
        neighbor_as     = var.ionos_bgp_as
        import_prefixes = ["172.31.254.0/24", "10.255.10.12/32"] # ionos配下のWireGuardピア(k8s1/k8s2/soichiro等)への復路 + Soichiro の管理 IP
        # 10.0.0.0/24(クラスタ LAN)。bird のフィルタは完全一致(net = <prefix>)で、k8s4 の経路表に 10.0.0.0/16 という経路は
        # 無いため、以前の "10.0.0.0/16" では、何も広告されていなかった(実機の `birdc show protocols all` で
        # IONOS・Oracle のどちらも `0 exported`。2026-10-05)。
        export_prefixes = ["10.0.0.0/24"]
      }
    ],
    # Oracle Cloud (計画中): oracle_wireguard_public_key が空文字の間はこのリストに
    # 何も追加されず、external_bgp_peers は従来通り1件のまま (no-op)。
    var.oracle_wireguard_public_key != "" ? [
      {
        local_ip        = trimsuffix(var.oracle_wireguard_address, "/24")
        local_as        = var.inuyama_asn
        neighbor_ip     = "172.31.253.2"
        neighbor_as     = var.oracle_bgp_as
        import_prefixes = ["10.255.10.12/32"] # Soichiro の管理 IP
        # 10.0.0.0/24(クラスタ LAN)。bird のフィルタは完全一致(net = <prefix>)で、k8s4 の経路表に 10.0.0.0/16 という経路は
        # 無いため、以前の "10.0.0.0/16" では、何も広告されていなかった(実機の `birdc show protocols all` で
        # IONOS・Oracle のどちらも `0 exported`。2026-10-05)。
        export_prefixes = ["10.0.0.0/24"]
        # Soichiro への経路は、遅延の小さい Oracle 経由(実測 約 12ms)を優先する。
        # IONOS 経由は、Inuyama↔IONOS 約 157ms + IONOS↔Soichiro 約 149ms で、約 300ms 台。
        # IONOS 経由は、Oracle が使えないときの予備(既定の 100)。
        local_pref = 200
      }
    ] : []
  )
}

module "kube_vip" {
  depends_on = [module.control_plane]
  source     = "../modules/kube-vip"

  host            = var.server_ip
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  vip_address   = var.kube_vip_address
  interface     = var.kube_vip_interface
  api_server_ip = var.kube_vip_api_server_ip
}

# kigawa-net/infra#178: 旧名称"alice"(廃止済みの外部VPSゲートウェイ)から
# gateway/inuyamaに改名。この2つのK8s Serviceは実際には現在ionos
# (hardware/ionosのinuyama_ingress_vip/minecraft_backend_vip、
# どちらも同じ10.0.0.240/10.0.0.241を指す)からの転送先として機能している
# 現役のインフラであり、機能自体は変更しない(名前のみ変更)。
resource "null_resource" "inuyama_gateway_services" {
  depends_on = [module.control_plane]

  triggers = {
    host                   = var.server_ip
    metallb_namespace      = var.gateway_metallb_namespace
    metallb_pool_name      = var.gateway_metallb_pool_name
    metallb_base_range     = var.gateway_metallb_base_range
    metallb_reserved_range = var.gateway_metallb_reserved_range
    ingress_vip            = var.gateway_ingress_vip
    minecraft_vip          = var.gateway_minecraft_vip
    # kigawa-net/infra#178: 旧alice-ingress/alice-minecraft削除ステップを追加した
    # ことでスクリプト内容が変わったが、上記の値自体は変化していないため、
    # このtriggerを明示的に更新して再実行(旧Service削除)を強制する
    script_revision = "alice-cleanup-2026-09-30"
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = data.external.ssh_key.result.value
  }

  provisioner "file" {
    content     = <<-SCRIPT
      #!/bin/bash
      set -eo pipefail
      export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      exec > >(tee -a /tmp/inuyama-gateway-services.log) 2>&1

      KUBECTL="kubectl --kubeconfig=/etc/kubernetes/admin.conf --server=https://${var.host}:6443 --request-timeout=30s"

      for attempt in 1 2 3 4 5; do
        if $KUBECTL get --raw=/readyz >/dev/null; then
          break
        fi
        if [ "$attempt" = "5" ]; then
          echo "kubernetes api is not ready"
          exit 1
        fi
        sleep 5
      done

      $KUBECTL -n ${var.gateway_metallb_namespace} patch ipaddresspool ${var.gateway_metallb_pool_name} --type=merge -p '{"spec":{"addresses":["${var.gateway_metallb_base_range}","${var.gateway_metallb_reserved_range}"],"autoAssign":true,"avoidBuggyIPs":true}}'

      # kigawa-net/infra#178: 旧名称alice-ingress/alice-minecraftはTerraformの
      # リソースとして追跡されていない(remote-execでkubectl applyしているだけ)ため、
      # inuyama-ingress/inuyama-minecraftへの改名だけでは自動的に削除されず、
      # MetalLBのVIP(10.0.0.240/241)を握ったまま残ってしまう。ここで明示的に削除し
      # VIPを新Serviceへ引き継がせる(--ignore-not-foundで再実行しても安全)
      $KUBECTL -n system delete svc alice-ingress --ignore-not-found
      $KUBECTL -n kigawa-net delete svc alice-minecraft --ignore-not-found

      cat > /tmp/inuyama-gateway-services.yaml <<YAML
      apiVersion: v1
      kind: Service
      metadata:
        name: inuyama-ingress
        namespace: system
        labels:
          app.kigawa.net/component: inuyama-gateway
          app.kigawa.net/managed-by: terraform
      spec:
        type: LoadBalancer
        loadBalancerIP: ${var.gateway_ingress_vip}
        externalTrafficPolicy: Cluster
        selector:
          app.kubernetes.io/instance: haproxy
          app.kubernetes.io/name: kubernetes-ingress
        ports:
        - appProtocol: http
          name: http
          port: 80
          protocol: TCP
          targetPort: http
        - appProtocol: https
          name: https
          port: 443
          protocol: TCP
          targetPort: https
      ---
      apiVersion: v1
      kind: Service
      metadata:
        name: inuyama-minecraft
        namespace: kigawa-net
        labels:
          app.kigawa.net/component: inuyama-gateway
          app.kigawa.net/managed-by: terraform
      spec:
        type: LoadBalancer
        loadBalancerIP: ${var.gateway_minecraft_vip}
        externalTrafficPolicy: Cluster
        selector:
          app: mc-router
        ports:
        - name: mc-router
          port: 25565
          protocol: TCP
          targetPort: 25565
      YAML

      $KUBECTL apply -f /tmp/inuyama-gateway-services.yaml
      $KUBECTL -n system get svc inuyama-ingress -o wide
      $KUBECTL -n kigawa-net get svc inuyama-minecraft -o wide
    SCRIPT
    destination = "/tmp/inuyama-gateway-services.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${data.external.sudo_password.result.value}' | sudo -S bash -c 'bash /tmp/inuyama-gateway-services.sh && rm -f /tmp/inuyama-gateway-services.sh /tmp/inuyama-gateway-services.yaml'",
    ]
  }
}

locals {
  knot_zones = {
    "kigawa.net"  = file("${path.module}/../zones/kigawa.net.zone")
    "onemc.world" = file("${path.module}/../zones/onemc.world.zone")
  }
}

module "knot" {
  depends_on = [module.control_plane]
  source     = "../modules/knot"

  host            = var.server_ip
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  zones = local.knot_zones
}

module "knot_resolver" {
  depends_on = [module.knot]
  source     = "../modules/knot-resolver"

  host                      = var.server_ip
  ssh_user                  = var.ssh_user
  ssh_private_key           = data.external.ssh_key.result.value
  sudo_password             = data.external.sudo_password.result.value
  dns_vip                   = var.dns_vip
  additional_listen_address = var.host
  zones_reload_trigger      = sha256(join("", values(local.knot_zones)))
}

module "keepalived" {
  source = "../modules/keepalived"

  host            = var.server_ip
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  interface         = var.kube_vip_interface
  virtual_router_id = 1
  priority          = 90
  virtual_ip        = var.gateway_vip
  state             = "BACKUP"
}

module "node_exporter" {
  source = "../modules/node-exporter"

  host            = var.server_ip
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value
}

module "dual_stack_network" {
  source = "../modules/dual-stack-network"

  host            = var.server_ip
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  interface       = var.kube_vip_interface
  primary_cidr    = "${var.host}/24"
  primary_gateway = "192.168.1.1"
  secondary_cidr  = "${var.server_ip}/24"
  nameservers     = ["192.168.1.1", "10.0.0.1"]
}
