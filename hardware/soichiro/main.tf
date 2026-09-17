# soichiro は Cloudflare Tunnel (cloudflared access ssh) 経由でのみSSH到達可能なため、
# 他ノードのようなTerraformネイティブSSH(connection block)は使えない
# (Goで実装されたTerraformのSSH通信機構は ~/.ssh/config の ProxyCommand を解釈しない)。
# そのため、この module だけ ../modules/wireguard / ../modules/node-exporter を使わず、
# ローカルの ssh/scp バイナリを local-exec から呼び出す方式にしている。
# 実行環境(terraform applyを実行するマシン)に cloudflared がインストールされている必要がある。

data "external" "join_info" {
  program = ["bash", "-c", <<-EOT
    ssh_key=$(bws secret get "${var.control_plane_ssh_key_bitwarden_id}" --color no | jq -r '.value')
    sudo_pass=$(bws secret get "${var.control_plane_sudo_password_bitwarden_id}" --color no | jq -r '.value')

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
    printf '{"token":"%s","ca_cert_hash":"%s"}' "$token" "$hash"
  EOT
  ]
}

locals {
  setup_script = <<-SCRIPT
    #!/bin/bash
    set -eo pipefail
    set -x
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    export DEBIAN_FRONTEND=noninteractive
    exec > >(tee -a /tmp/soichiro-setup.log) 2>&1

    apt-get update -y
    apt-get install -y wireguard kmod ca-certificates curl gpg apt-transport-https

    # --- WireGuard client setup (modules/wireguardと同等の内容をこのnodeにインライン化) ---
    install -d -m 700 /etc/wireguard

    if [ ! -f /etc/wireguard/privatekey ]; then
      wg genkey > /etc/wireguard/privatekey
      wg pubkey < /etc/wireguard/privatekey > /etc/wireguard/publickey
    fi
    chmod 600 /etc/wireguard/privatekey
    wg_private_key=$(cat /etc/wireguard/privatekey)

    cat > /etc/wireguard/wg0.conf <<WG_EOF
    [Interface]
    Address = ${var.wireguard_address}
    PrivateKey = $wg_private_key

    [Peer]
    PublicKey = ${var.wireguard_server_public_key}
    AllowedIPs = ${join(", ", var.wireguard_server_allowed_ips)}
    Endpoint = ${var.wireguard_server_endpoint}
    PersistentKeepalive = 25
    WG_EOF
    chmod 600 /etc/wireguard/wg0.conf

    systemctl enable wg-quick@wg0
    systemctl restart wg-quick@wg0

    echo "=== WireGuard public key (alice側のsoichiro_wireguard_public_keyに設定すること) ==="
    cat /etc/wireguard/publickey

    # --- kubelet/kubeadm/containerd + join (k8s-worker5と同等) ---
    swapoff -a
    sed -i '/ swap / s/^\(.*\)$/#\1/' /etc/fstab

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

    # --- node_exporter (modules/node-exporterと同等の内容をこのnodeにインライン化) ---
    id node_exporter &>/dev/null || useradd --no-create-home --shell /bin/false node_exporter

    cd /tmp
    curl -fsSL https://github.com/prometheus/node_exporter/releases/download/v${var.node_exporter_version}/node_exporter-${var.node_exporter_version}.linux-amd64.tar.gz | tar xz
    install -m 755 node_exporter-${var.node_exporter_version}.linux-amd64/node_exporter /usr/local/bin/node_exporter
    rm -rf node_exporter-${var.node_exporter_version}.linux-amd64

    cat > /etc/systemd/system/node_exporter.service <<NE_EOF
    [Unit]
    Description=Prometheus Node Exporter
    After=network.target

    [Service]
    User=node_exporter
    Group=node_exporter
    Type=simple
    ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9100
    Restart=on-failure

    [Install]
    WantedBy=multi-user.target
    NE_EOF

    systemctl daemon-reload
    systemctl enable --now node_exporter
    systemctl restart node_exporter
  SCRIPT
}

resource "local_file" "setup_script" {
  filename        = "${path.module}/.generated/soichiro-setup.sh"
  content         = local.setup_script
  file_permission = "0600"
}

resource "null_resource" "soichiro_setup" {
  depends_on = [local_file.setup_script, data.external.join_info]

  triggers = {
    script_hash = sha256(local.setup_script)
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eo pipefail
      scp -i "${var.ssh_private_key_path}" -o StrictHostKeyChecking=accept-new -o "ProxyCommand=cloudflared access ssh --hostname %h" "${local_file.setup_script.filename}" "${var.ssh_user}@${var.ssh_hostname}:/tmp/soichiro-setup.sh"
      ssh -i "${var.ssh_private_key_path}" -o StrictHostKeyChecking=accept-new -o "ProxyCommand=cloudflared access ssh --hostname %h" "${var.ssh_user}@${var.ssh_hostname}" "echo '${var.sudo_password}' | sudo -S bash /tmp/soichiro-setup.sh && rm -f /tmp/soichiro-setup.sh"
    EOT
  }
}
