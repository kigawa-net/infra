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
#
# IONOS からの通信を受けるインターフェース: wg1(IONOS の wg0 の k8s4 の peer)と、専用リンク(wg-ionos-gw。kigawa-net/infra#238)。
# 切り替え(段階 3)で、IONOS からの通信が専用リンクに入るようになる前に、専用リンクにも同じルールを足しておく
# (wg1 のルールは、そのまま残す。ルールを足すだけで、今の通信には影響しない)。
locals {
  ci_ssh_forward_interfaces = [var.ionos_wireguard_interface, var.ionos_link_interface]

  ci_ssh_forward_script = <<-SCRIPT
    #!/bin/bash
    set -eo pipefail
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    IPT="iptables -w 5"
    LAN_IF="${var.lan_interface}"
    CI="${var.ci_runner_wireguard_address}"
    CHAIN=CI-WG-SSH

    # 専用チェーンを作り直す(再実行しても重複しない)
    $IPT -N $CHAIN 2>/dev/null || $IPT -F $CHAIN
    %{for t in var.ci_ssh_forward_targets~}
    $IPT -A $CHAIN -d ${t}/32 -p tcp --dport 22 -j ACCEPT
    %{endfor~}
    $IPT -A $CHAIN -j DROP

    %{for ifc in local.ci_ssh_forward_interfaces~}
    # ${ifc} から入る、CIランナー発のLAN宛通信は専用チェーンで評価(SSH以外は破棄)
    $IPT -C FORWARD -i ${ifc} -o $LAN_IF -s $CI -d 192.168.1.0/24 -j $CHAIN 2>/dev/null \
      || $IPT -I FORWARD 1 -i ${ifc} -o $LAN_IF -s $CI -d 192.168.1.0/24 -j $CHAIN
    # 復路(確立済みのみ)
    $IPT -C FORWARD -i $LAN_IF -o ${ifc} -s 192.168.1.0/24 -d $CI -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
      || $IPT -I FORWARD 1 -i $LAN_IF -o ${ifc} -s 192.168.1.0/24 -d $CI -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    %{endfor~}

    # 送信元NAT(許可した宛先のtcp/22のみ)。出力インターフェースは LAN なので、IONOS 側のインターフェースによらない
    %{for t in var.ci_ssh_forward_targets~}
    $IPT -t nat -C POSTROUTING -s $CI/32 -d ${t}/32 -o $LAN_IF -p tcp --dport 22 -j MASQUERADE 2>/dev/null \
      || $IPT -t nat -A POSTROUTING -s $CI/32 -d ${t}/32 -o $LAN_IF -p tcp --dport 22 -j MASQUERADE
    %{endfor~}
  SCRIPT
}

resource "null_resource" "ci_ssh_forward" {
  depends_on = [null_resource.ionos_wireguard]

  triggers = {
    host    = var.server_ip
    wg_ifs  = join(",", local.ci_ssh_forward_interfaces)
    lan_if  = var.lan_interface
    ci_addr = var.ci_runner_wireguard_address
    targets = join(",", var.ci_ssh_forward_targets)
    version = "2"
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = data.external.ssh_key.result.value
  }

  provisioner "file" {
    content     = local.ci_ssh_forward_script
    destination = "/tmp/ci-ssh-forward.sh"
  }

  provisioner "file" {
    content     = <<-UNIT
      [Unit]
      Description=Allow CI runner SSH to LAN workers via wg1 / wg-ionos-gw (forward + MASQUERADE, tcp/22 only)
      After=network-online.target wg-quick@${var.ionos_wireguard_interface}.service wg-quick@${var.ionos_link_interface}.service
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
      # AllowedIPs からの経路の自動追加を止める。wg1 の AllowedIPs の 10.255.10.12/32 は、wg-oracle(Oracle 経由が主経路)の AllowedIPs にもあり、
      # 再起動の起動順で wg1 が先に経路を取ると、wg-oracle の wg-quick が File exists で失敗した(2026-10-18、4 日間)。
      # 172.31.254.0/24 の on-link の経路(BGP の経路より優先される誤った経路)も、再起動のたびに復活していた。必要な経路は BGP が学習する。
      Table = off

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

# IONOS との専用リンク(kigawa-net/infra#238、案 D)。peer は IONOS の 1 つだけ、AllowedIPs = 0.0.0.0/0、Table = off(経路は BGP に任せる)。
# stage 2 まで: 経路を変えない。k8s4 は、このリンクから IONOS の経路を取り込まない(import なし)。IONOS のカーネルの経路(wg0)が
# 主のままで、既存の wg1 のセッションにも触れない。設定が変わったとき、または停止しているときだけ、このインターフェースを再起動する。
locals {
  ionos_gateway_link_script = <<-SCRIPT
    #!/bin/bash
    set -eo pipefail
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    umask 077
    exec > >(tee -a /tmp/ionos-gateway-link-setup.log) 2>&1

    case "${var.ionos_link_interface}" in
      ""|*[!a-zA-Z0-9._-]*)
        echo "ionos_link_interface contains unsupported characters"
        exit 1
        ;;
    esac

    if [ ! -f /etc/wireguard/inuyama_private.key ]; then
      echo "/etc/wireguard/inuyama_private.key not found"
      exit 1
    fi
    inuyama_private_key=$(cat /etc/wireguard/inuyama_private.key)

    conf=/etc/wireguard/${var.ionos_link_interface}.conf
    cat > "$conf.new" <<WGCONF
    [Interface]
    Address = ${var.ionos_link_address}
    PrivateKey = $inuyama_private_key
    Table = off
    MTU = ${var.wireguard_mtu}

    [Peer]
    PublicKey = ${var.ionos_wireguard_public_key}
    AllowedIPs = 0.0.0.0/0
    Endpoint = ${var.ionos_link_endpoint}
    PersistentKeepalive = 25
    WGCONF
    chmod 600 "$conf.new"
    # 設定を置いてから再起動するまでに、後ろの手順が失敗しても、次の実行で再起動が飛ばされないよう、保留のマーカーを残す
    marker=/etc/wireguard/.${var.ionos_link_interface}-restart-pending
    if ! cmp -s "$conf.new" "$conf"; then
      touch "$marker"
    fi
    mv -f "$conf.new" "$conf"

    systemctl enable wg-quick@${var.ionos_link_interface}
    if [ -e "$marker" ] || ! systemctl is-active --quiet wg-quick@${var.ionos_link_interface}; then
      systemctl restart wg-quick@${var.ionos_link_interface}
      rm -f "$marker"
    fi
    wg show ${var.ionos_link_interface}
  SCRIPT
}

resource "null_resource" "ionos_gateway_link" {
  depends_on = [null_resource.ionos_wireguard]

  lifecycle {
    # 稼働中のトンネル(wg1・wg-oracle など)を、誤って上書き・再起動しないこと(Terraform 1.6 では、variable の validation から
    # 他の変数を参照できないため、ここで確かめる)
    precondition {
      condition = (
        var.ionos_link_interface != var.ionos_wireguard_interface &&
        var.ionos_link_interface != var.oracle_wireguard_interface &&
        var.ionos_link_interface != var.inuyama_wireguard_interface &&
        can(regex("^wg-[a-z0-9-]{1,11}$", var.ionos_link_interface)) &&
        can(cidrhost(var.ionos_link_address, 0)) && can(cidrhost("${var.ionos_link_peer_address}/30", 0)) &&
        cidrhost(var.ionos_link_address, 0) == cidrhost("${var.ionos_link_peer_address}/30", 0) &&
        cidrhost(var.ionos_link_address, 0) != cidrhost(var.ionos_wireguard_address, 0) &&
        cidrhost(var.ionos_link_address, 0) != cidrhost(var.oracle_wireguard_address, 0)
      )
      error_message = "ionos_link_interface は wg- で始まり、wg1・wg-oracle など既存のインターフェースと別に、ionos_link_address と ionos_link_peer_address は同じ /30 で、既存のトンネルのネットワークと別にしてください。"
    }
  }

  triggers = {
    host             = var.server_ip
    interface        = var.ionos_link_interface
    address          = var.ionos_link_address
    ionos_public_key = sha256(var.ionos_wireguard_public_key)
    endpoint         = var.ionos_link_endpoint
    setup_script     = sha256(local.ionos_gateway_link_script)
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = data.external.ssh_key.result.value
  }

  provisioner "file" {
    content     = local.ionos_gateway_link_script
    destination = "/tmp/ionos-gateway-link-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${data.external.sudo_password.result.value}' | sudo -S bash /tmp/ionos-gateway-link-setup.sh && rm -f /tmp/ionos-gateway-link-setup.sh",
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
      # AllowedIPs からの経路の自動追加を止め(wg1 との起動順の競合を避ける。上の wg1 のコメント)、必要な経路だけを、衝突しない replace で入れる。
      Table = off
      %{for r in var.oracle_wireguard_routes~}
      PostUp = ip route replace ${r} dev %i
      %{endfor~}

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

# 稼働中の wg1 / wg-oracle の設定(/etc/wireguard/*.conf)に、`Table = off` と PostUp を、**インターフェースを再起動せずに**追記する(kigawa-net/infra#238)。
# 上の null_resource の生成元には、同じ内容を入れてあるが、triggers が変わらないので、稼働中の設定には、再実行されない(再実行すると wg1 が再起動し、
# IONOS との接続と、CI の SSH 経路が切れる)。次に wg-quick が起動するとき(ノードの再起動)から効く。
module "wg_conf_table_off" {
  depends_on = [null_resource.ionos_wireguard, null_resource.oracle_wireguard]
  source     = "../modules/wg-conf-table-off"

  host            = var.server_ip
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  interfaces = {
    (var.ionos_wireguard_interface) = { post_up = [] }
    (var.oracle_wireguard_interface) = {
      post_up = [for r in var.oracle_wireguard_routes : "ip route replace ${r} dev %i"]
    }
  }
}

# BIRD から FRR へ移行する (#210)。k8s1・k8s2 は移行済み。k8s4 は外部ピア(IONOS・Oracle)を持つので最後。
# 手順は hardware/modules/bgp-frr/RUNBOOK-step2-k8s1.md。マージ前に必ず手順書を読み、合意した時間に行うこと。
locals {
  # IONOS から取り込む prefix: ionos 配下の WireGuard ピア(k8s1 / k8s2 / CI ランナー / Soichiro など)への復路 + Soichiro の管理 IP
  ionos_import_prefixes = ["172.31.254.0/24", "10.255.10.12/32"]
}

module "bgp" {
  depends_on = [module.control_plane, null_resource.inuyama_wireguard, null_resource.ionos_wireguard, null_resource.ionos_gateway_link, null_resource.oracle_wireguard]
  source     = "../modules/bgp-frr"

  host            = var.server_ip
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  bgp_router_id   = var.server_ip
  bgp_local_as    = var.bgp_local_as
  bgp_peers       = var.bgp_peers
  advertised_vips = var.dns_vip != "" ? [var.dns_vip] : []

  # BGP デーモン/OS が止まった control-plane の経路を、既定(hold 180 秒)より早く撤回する (issue #232)。
  # iBGP のメッシュ(k8s1/k8s2/k8s4)だけに適用する。外部の eBGP ピアには適用しない。
  ibgp_keepalive_seconds = 3
  ibgp_hold_seconds      = 9

  # BIRD の protocol direct 相当(許可リスト)。実機(2026-10-06)の BIRD が direct として iBGP / 外部に流していた経路のうち、必要なもの:
  #   10.0.0.0/24      : IONOS・Oracle へ広告するクラスタ LAN
  #   10.0.0.100/32    : API VIP(kube-vip の保持ノードで直結)
  #   10.0.0.254/32    : ゲートウェイ VIP(keepalived)
  #   172.31.253.0/24  : Oracle との WireGuard(wg-oracle)。他ノードが Oracle 側のアドレスへ k8s4 経由で届くため
  #   172.31.254.0/30  : IONOS との WireGuard(wg1)の遷移ネット。同上
  #   192.168.1.53/32  : k8s4 の lo にあるアドレス。BIRD が iBGP に流していた。用途は未確認(現状維持のため残す)
  #   192.168.1.0/24  : worker の LAN。bao-02/03 へ eBGP で広告する(下の external_bgp_peers)。export は connected 経路が BGP に入っていないと効かない
  redistribute_connected_prefixes = ["10.0.0.0/24", "10.0.0.100/32", "10.0.0.254/32", "172.31.253.0/24", "172.31.254.0/30", "192.168.1.0/24", "192.168.1.53/32"]
  # 同一ホストの kube-vip との BGP は FRR では張れない (bgp-frr の README 参照)。VIP は直結経路で伝搬する。
  enable_kube_vip_peer = false
  # FRR の起動前に BIRD の static Pod を止める。
  stop_bird = true

  external_bgp_peers = concat(
    [
      {
        local_ip    = trimsuffix(var.ionos_wireguard_address, "/30")
        local_as    = var.inuyama_asn
        neighbor_ip = "172.31.254.2"
        neighbor_as = var.ionos_bgp_as
        # ionos配下のWireGuardピア(k8s1/k8s2/soichiro等)への復路 + Soichiro の管理 IP。専用リンクが主(ionos_link_primary)のときは、
        # こちら(wg1 の eBGP)からは取り込まない(同じ prefix の経路が 2 つになり、k8s4 の IONOS 方面の出口が、どちらか不定になるため)。
        import_prefixes = var.ionos_link_primary ? [] : local.ionos_import_prefixes
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
    ] : [],
    # IONOS との専用リンク(kigawa-net/infra#238)。ionos_link_primary = true(切り替え後)のとき、k8s4 の IONOS 方面の出口は、
    # このリンクになる(172.31.254.0/24 と Soichiro の管理 IP を、ここから取り込む)。false(切り替え前)のときは、何も取り込まず、
    # 10.0.0.0/24 を広告するだけ(取り込むと、wg1 の eBGP と同じ prefix の経路が 2 つになり、不定になる)。元に戻すときは false。
    # **必ず、リストの最後に足すこと**: bgp-frr module は、peer ごとに、リストの添字で `EXT-<添字>-IN/OUT` の prefix-list と
    # route-map を作る。既存の peer(Oracle など)より前に入れると、添字がずれて、reload の途中で、既存の peer の import が、
    # 一時的に deny-all になる(Soichiro への主経路が消える)。
    [
      {
        local_ip        = trimsuffix(var.ionos_link_address, "/30")
        local_as        = var.inuyama_asn
        neighbor_ip     = var.ionos_link_peer_address
        neighbor_as     = var.ionos_bgp_as
        import_prefixes = var.ionos_link_primary ? local.ionos_import_prefixes : []
        export_prefixes = ["10.0.0.0/24"]
        # k8s2 の専用リンクから取り込む同じ prefix(100)より優先する(iBGP で local-preference が伝わり、k8s1 などの Inuyama の
        # ノードは、通常は k8s4 を使い、k8s4 の経路が消えたときだけ、k8s2 を使う)
        local_pref = 200
      }
    ],
    # OpenBao の bao-02 / bao-03(EasyTier のオーバーレイ上の eBGP。設計: hardware/modules/frr-overlay-peer)。
    # 相手へは 10.0.0.0/24(クラスタ LAN)と 192.168.1.0/24(worker の LAN。Pod の外向きは、この LAN の node IP に MASQUERADE される)だけを出す。
    # 相手からは何も取り込まない(import_prefixes = [])。**必ず、リストの最後に足すこと**(添字で EXT-<添字> の名前が決まる)。
    var.easytier_enabled ? [
      {
        local_ip        = trimsuffix(var.easytier_overlay_address, "/24")
        local_as        = var.inuyama_asn
        neighbor_ip     = "10.250.0.1"
        neighbor_as     = 65041
        import_prefixes = []
        export_prefixes = ["10.0.0.0/24", "192.168.1.0/24"]
      },
      {
        local_ip        = trimsuffix(var.easytier_overlay_address, "/24")
        local_as        = var.inuyama_asn
        neighbor_ip     = "10.250.0.31"
        neighbor_as     = 65042
        import_prefixes = []
        export_prefixes = ["10.0.0.0/24", "192.168.1.0/24"]
      },
    ] : [],
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
  health_peers  = var.kube_vip_health_peers
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

  # Core Router VIP (#241 Phase 2)。LAN(192.168.1.0/24)側の仮想コアルーターの next-hop。
  extra_instances = [{
    name              = "VI_CORE"
    virtual_router_id = 2
    priority          = 90
    state             = "BACKUP"
    virtual_ip        = var.core_router_vip
  }]
}

# journald の上限(/ の枯渇対策、issue #254)。
module "journald_limit" {
  source = "../modules/journald-limit"

  host            = var.server_ip
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value
}

# systemd-networkd が、外部のポリシールールと経路を、再起動のたびに消さないようにする(kigawa-net/infra#238)。
# 2026-10-21、k8s2 の networkd の再起動で、wg1 の PostUp のポリシールール(#282)が消え、IONOS から VIP と k8s2 に届かなくなった。
# networkd は再起動しない(次の起動から有効)。
module "networkd_keep_foreign" {
  source = "../modules/networkd-keep-foreign"

  host            = var.server_ip
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value
}

# MAAS の Rack コントローラー(kigawa-net/infra#207、docs/maas-design.md)。maas_rack_enabled = false(既定)のときは、何もしない。
# data "external" の result は sensitive にならない(terraform show に出る)ので、module に渡すときに sensitive() で包む。
data "external" "maas_secret" {
  count = var.maas_rack_enabled ? 1 : 0

  program = ["bash", "-c", <<-EOT
    source "${path.module}/../../lib/bws-retry.sh"
    value=$(bws_get_value "${var.maas_secret_bitwarden_id}") || exit 1
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

module "maas_rack" {
  source = "../modules/maas-rack"

  enabled           = var.maas_rack_enabled
  maas_version      = var.maas_rack_version
  host              = var.server_ip
  ssh_user          = var.ssh_user
  ssh_private_key   = data.external.ssh_key.result.value
  sudo_password     = data.external.sudo_password.result.value
  maas_secret       = var.maas_rack_enabled ? sensitive(data.external.maas_secret[0].result.value) : ""
  lan_address       = var.maas_rack_lan_address
  dhcp_peer_address = var.maas_rack_dhcp_peer_address
}

module "node_exporter" {
  source = "../modules/node-exporter"

  host            = var.server_ip
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  # manifests-guard(/etc/kubernetes/manifests の余分なファイルの検知、issue #263)のメトリクスを、Prometheus へ出す。
  # manifests-guard モジュールの textfile_dir(既定は同じ値)と合わせること。
  textfile_directory = "/var/lib/node_exporter/textfile"
}

# /etc/kubernetes/manifests の余分なファイル(.bak など)と、pod 名の重複を検知する。検知するだけで、ファイルは触らない (issue #263)。
module "manifests_guard" {
  source = "../modules/manifests-guard"

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

# Karmada の etcd #1(worker3 の Pod)から Soichiro(10.255.10.12)への peer / client 通信の戻りの経路を作る。
# Pod の外向きの通信は flannel でノードのアドレス(192.168.1.130)に変換され、k8s1 / k8s2 / k8s4 を経由して
# wg-oracle から出るため、Soichiro から見た送信元が 192.168.1.130 になる。Soichiro は 192.168.1.0/24 への経路を
# 持たないので、SYN-ACK が戻れず、Inuyama のログに `i/o timeout` が出ていた(2026-10-05、tcpdump で確認)。
# Soichiro 宛の etcd(tcp/2379,2380)だけを、WireGuard の出口で MASQUERADE し、送信元を k8s4 のトンネルのアドレス
# (wg-oracle: 172.31.253.1、wg1: 172.31.254.1)にする。k8s4 の FORWARD は暗黙 ACCEPT のため、FORWARD は触らない。
locals {
  # IONOS 方面のインターフェースは、wg1 と、専用リンク(wg-ionos-gw。kigawa-net/infra#238)。切り替え(段階 3)で、
  # k8s4 の IONOS 方面の出口が専用リンクに移る前に、専用リンクにも MASQUERADE を足しておく(今の通信には影響しない)。
  # 注意: 専用リンクの出口は、MASQUERADE でなく、wg1 のアドレス(172.31.254.1)への SNAT にする(スクリプトを参照)。MASQUERADE だと
  # 送信元が 172.31.252.2 になり、Soichiro は 172.31.252.0/30 への経路を持たないので、戻りが届かない(Soichiro 宛の etcd は、
  # 通常は Oracle 経由。IONOS 経由は、Oracle が使えないときの予備)。
  etcd_peer_masquerade_interfaces = [var.oracle_wireguard_interface, var.ionos_wireguard_interface, var.ionos_link_interface]

  etcd_peer_masquerade_script = <<-SCRIPT
    #!/bin/bash
    set -eo pipefail
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    IPT="iptables -w 5"
    SRC="${var.etcd_peer_masquerade_source_cidr}"
    %{for dst in var.etcd_peer_masquerade_destinations~}
    %{for ifc in local.etcd_peer_masquerade_interfaces~}
    %{if ifc == var.ionos_link_interface~}
    # 専用リンクの出口は、MASQUERADE(送信元がリンクの主アドレス 172.31.252.2 になる)でなく、wg1 のアドレスに SNAT する。
    # Soichiro は 172.31.254.0/24(IONOS の wg0 のネットワーク)への経路を持つが、172.31.252.0/30 への経路は持たない。
    # 先に入れた MASQUERADE のルールがあれば、消す(先に合致して、SNAT が効かないため)。
    $IPT -t nat -D POSTROUTING -s $SRC -d ${dst}/32 -o ${ifc} -p tcp -m multiport --dports 2379,2380 -j MASQUERADE 2>/dev/null || true
    $IPT -t nat -C POSTROUTING -s $SRC -d ${dst}/32 -o ${ifc} -p tcp -m multiport --dports 2379,2380 -j SNAT --to-source ${split("/", var.ionos_wireguard_address)[0]} 2>/dev/null \
      || $IPT -t nat -A POSTROUTING -s $SRC -d ${dst}/32 -o ${ifc} -p tcp -m multiport --dports 2379,2380 -j SNAT --to-source ${split("/", var.ionos_wireguard_address)[0]}
    %{else~}
    $IPT -t nat -C POSTROUTING -s $SRC -d ${dst}/32 -o ${ifc} -p tcp -m multiport --dports 2379,2380 -j MASQUERADE 2>/dev/null \
      || $IPT -t nat -A POSTROUTING -s $SRC -d ${dst}/32 -o ${ifc} -p tcp -m multiport --dports 2379,2380 -j MASQUERADE
    %{endif~}
    %{endfor~}
    %{endfor~}
  SCRIPT
}

resource "null_resource" "etcd_peer_masquerade" {
  depends_on = [null_resource.ionos_wireguard, null_resource.ionos_gateway_link, null_resource.oracle_wireguard]

  triggers = {
    host         = var.server_ip
    source       = var.etcd_peer_masquerade_source_cidr
    destinations = join(",", var.etcd_peer_masquerade_destinations)
    interfaces   = join(",", local.etcd_peer_masquerade_interfaces)
    script_hash  = sha256(local.etcd_peer_masquerade_script)
  }

  connection {
    type        = "ssh"
    host        = var.server_ip
    user        = var.ssh_user
    private_key = data.external.ssh_key.result.value
  }

  provisioner "file" {
    content     = local.etcd_peer_masquerade_script
    destination = "/tmp/etcd-peer-masquerade.sh"
  }

  provisioner "file" {
    content     = <<-UNIT
      [Unit]
      Description=MASQUERADE Karmada etcd traffic (worker LAN -> Soichiro) at the WireGuard egress
      After=network-online.target wg-quick@${var.oracle_wireguard_interface}.service wg-quick@${var.ionos_wireguard_interface}.service wg-quick@${var.ionos_link_interface}.service
      Wants=network-online.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/local/bin/etcd-peer-masquerade.sh

      [Install]
      WantedBy=multi-user.target
    UNIT
    destination = "/tmp/etcd-peer-masquerade.service"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${data.external.sudo_password.result.value}' | sudo -S bash -c 'install -m 755 /tmp/etcd-peer-masquerade.sh /usr/local/bin/etcd-peer-masquerade.sh && install -m 644 /tmp/etcd-peer-masquerade.service /etc/systemd/system/etcd-peer-masquerade.service && systemctl daemon-reload && systemctl enable etcd-peer-masquerade.service && systemctl restart etcd-peer-masquerade.service && rm -f /tmp/etcd-peer-masquerade.sh /tmp/etcd-peer-masquerade.service'",
    ]
  }
}

# 内部ドメイン(kigawa.net など)を、kresd に向ける。ノードは、自宅ルーターで k8s.kigawa.net を引いており、
# ルーターの上流(k8s2)が止まると、kubelet が API に繋がらなくなった(2026-10-04)。
module "node_dns" {
  source = "../modules/node-dns"

  host            = var.server_ip
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value
}

# EasyTier のネットワーク Secret(bws から読む。空なら止める)
data "external" "easytier_network_secret" {
  count = var.easytier_enabled ? 1 : 0

  program = ["bash", "-c", <<-EOT
    source "${path.module}/../../lib/bws-retry.sh"
    if [ -z "${var.easytier_network_secret_bitwarden_id}" ]; then echo "easytier_network_secret_bitwarden_id が未設定" >&2; exit 1; fi
    value=$(bws_get_value "${var.easytier_network_secret_bitwarden_id}") || exit 1
    if [ -z "$value" ] || [ "$value" = "null" ]; then echo "easytier_network_secret: bws secret is empty" >&2; exit 1; fi
    jq -n --arg value "$value" '{"value": $value}'
  EOT
  ]
}

# Inuyama(NAT 配下)の Overlay ノード。公開 Peer 2 台へ接続する。WireGuard・FRR・BGP・Kubernetes には触れない。
# control-plane は ufw を使わないため、Overlay からの受信は、modules/overlay-firewall(iptables)で、easytier より先に許可リスト制にする(既定は何も許可しない)。
module "overlay_firewall" {
  source = "../modules/overlay-firewall"
  count  = var.easytier_enabled ? 1 : 0

  host            = var.server_ip
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  overlay_cidr  = "${cidrhost(var.easytier_overlay_address, 0)}/${split("/", var.easytier_overlay_address)[1]}"
  overlay_allow = var.easytier_overlay_allow
}

module "easytier" {
  source     = "../modules/easytier"
  count      = var.easytier_enabled ? 1 : 0
  depends_on = [module.overlay_firewall]

  host            = var.server_ip
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  easytier_version = var.easytier_version
  easytier_sha256  = var.easytier_sha256
  network_name     = var.easytier_network_name
  network_secret   = data.external.easytier_network_secret[0].result.value
  overlay_address  = var.easytier_overlay_address
  peers            = var.easytier_peers
}
