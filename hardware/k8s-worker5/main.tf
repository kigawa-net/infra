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

data "external" "join_info" {
  program = ["bash", "-c", <<-EOT
    source "${path.module}/../../lib/bws-retry.sh"
    ssh_key=$(bws_get_value "${var.control_plane_ssh_key_bitwarden_id}") || exit 1
    sudo_pass=$(bws_get_value "${var.sudo_password_bitwarden_id}") || exit 1
    if [ -z "$ssh_key" ] || [ "$ssh_key" = "null" ] || [ -z "$sudo_pass" ] || [ "$sudo_pass" = "null" ]; then
      echo "join_info: bws secret is empty" >&2
      exit 1
    fi

    tmpkey=$(mktemp)
    chmod 600 "$tmpkey"
    printf '%s\n' "$ssh_key" > "$tmpkey"

    cmd=$(ssh \
      -i "$tmpkey" \
      -o StrictHostKeyChecking=no \
      -o BatchMode=yes \
      "${var.control_plane_ssh_user}@${var.control_plane_host}" \
      "echo '$sudo_pass' | sudo -S kubeadm token create --print-join-command 2>/dev/null")

    rm -f "$tmpkey"

    token=$(printf '%s' "$cmd" | grep -oP '(?<=--token )\S+')
    hash=$(printf '%s' "$cmd"  | grep -oP '(?<=--discovery-token-ca-cert-hash )\S+')
    if [ -z "$token" ] || [ -z "$hash" ]; then
      echo "join_info: kubeadm token create did not return token/ca_cert_hash" >&2
      exit 1
    fi
    printf '{"token":"%s","ca_cert_hash":"%s"}' "$token" "$hash"
  EOT
  ]
}

resource "null_resource" "worker_node" {
  triggers = {
    host = var.host
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = data.external.ssh_key.result.value
  }

  provisioner "file" {
    content     = <<-SCRIPT
      #!/bin/bash
      set -eo pipefail
      set -x
      export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      exec > >(tee -a /tmp/k8s-setup.log)
      exec 2>&1

      cleanup() {
        if [ $? -ne 0 ]; then
          echo "[cleanup] setup failed, rolling back..."
          kubeadm reset -f 2>/dev/null || true
          apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
          apt-get remove -y --purge kubelet kubeadm kubectl 2>/dev/null || true
          apt-get remove -y --purge containerd 2>/dev/null || true
          rm -f /etc/apt/sources.list.d/kubernetes.list
          rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
          rm -f /etc/modules-load.d/k8s.conf
          rm -f /etc/sysctl.d/k8s.conf
          apt-get autoremove -y 2>/dev/null || true
          echo "[cleanup] rollback complete"
        fi
      }
      trap cleanup EXIT

      swapoff -a
      sed -i '/ swap / s/^\(.*\)$/#\1/' /etc/fstab

      apt-get update -y
      apt-get install -y kmod

      printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
      modprobe overlay || true
      modprobe br_netfilter || true

      printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n' > /etc/sysctl.d/k8s.conf
      sysctl --system

      apt-get install -y containerd
      mkdir -p /etc/containerd
      containerd config default > /etc/containerd/config.toml
      sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
      systemctl enable --now containerd

      apt-get install -y apt-transport-https ca-certificates curl gpg
      mkdir -p /etc/apt/keyrings
      curl -fsSL https://pkgs.k8s.io/core:/stable:/v${var.k8s_version}/deb/Release.key | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
      echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${var.k8s_version}/deb/ /' > /etc/apt/sources.list.d/kubernetes.list
      apt-get update -y
      apt-get install -y kubelet kubeadm kubectl
      apt-mark hold kubelet kubeadm kubectl

      if [ ! -f /etc/kubernetes/kubelet.conf ]; then
        kubeadm join ${var.k8s_endpoint}:6443 \
          --token ${data.external.join_info.result.token} \
          --discovery-token-ca-cert-hash ${data.external.join_info.result.ca_cert_hash} \
           || { echo "kubeadm join failed with exit code: $?"; exit 1; }
      fi
    SCRIPT
    destination = "/tmp/k8s-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${data.external.sudo_password.result.value}' | sudo -S bash /tmp/k8s-setup.sh && rm -f /tmp/k8s-setup.sh",
    ]
  }
}

module "node_exporter" {
  source = "../modules/node-exporter"

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value
}

module "cluster_route" {
  source = "../modules/cluster-route"

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value
  # Core Router VIP(#241)1 本。k8s1 / k8s2 / k8s4 の keepalived(VRRP)が持つ VIP で、MASTER の 1 台に転送を任せる。
  # 以前は k8s1 / k8s2 / k8s4 の 3 台への ECMP だった。ECMP のハッシュ方式が既定(fib_multipath_hash_policy=0、
  # 宛先と送信元のアドレスのみ)のため、あるゲートウェイがダウンすると、そこに振られる通信(worker3 -> API の VIP
  # 10.0.0.100 など)が、常にそこへ流れ続け、`no route to host` になった(2026-10-05、k8s2 のダウン中に worker3 が
  # NotReady になった: issue #228)。VRRP の failover(約 1 秒)に任せることで、この固定を無くす。
  # 負荷分散はなくなる(MASTER の 1 台に集まる)。
  gateways = [var.core_router_vip]

  # Karmada(Soichiro の VM)への経路。Inuyama の BGP(k8s4)が学習する 10.255.10.12/32 を含む範囲を、
  # クラスタLANと同じ next-hop(k8s1/k8s2/k8s4)に向ける。
  # 172.31.254.2/32: IONOS の Karmada etcd #3(WireGuard のアドレス)。Inuyama の etcd #1 が、メンバー間の通信に使う。
  extra_destination_cidrs = ["10.255.10.0/24", "172.31.254.2/32"]
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
