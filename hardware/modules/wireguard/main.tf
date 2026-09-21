locals {
  # ネストしたヒアドキュメント(bashスクリプト内のcat <<WG_EOF)の中で
  # Terraformの制御構文(%{ for ~} ... %{ endfor ~})を直接使うと、
  # 空白除去(~)の影響でWG_EOFの終端がbashに正しく認識されず、
  # スクリプトの残り部分が丸ごとヒアドキュメントに飲み込まれてしまう
  # (壊れたスクリプトがエラーにならず「成功」してしまう)。
  # そのため事前に1つの文字列としてレンダリングし、単純な${}展開のみで
  # ヒアドキュメントに埋め込む。
  postup_lines = join("\n", [for ip in var.server_allowed_ips : "      PostUp = ip route replace ${ip} dev %i scope link"])
}

resource "null_resource" "wireguard" {
  triggers = {
    host              = var.host
    wireguard_address = var.wireguard_address
    server_endpoint   = var.server_endpoint
    server_public_key = sha256(var.server_public_key)
    allowed_ips       = join(",", var.server_allowed_ips)
    setup_version     = "6"
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = <<-SCRIPT
      #!/bin/bash
      set -eo pipefail
      export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      export DEBIAN_FRONTEND=noninteractive
      umask 077
      exec > >(tee -a /tmp/wireguard-setup.log) 2>&1

      # 同一ホストに対してこのモジュールが複数回呼び出される場合(k8s1のalice向け
      # module.wireguardとionos向けmodule.wireguard_ionosなど)、terraformは
      # 独立したリソースとして並列にapplyするため、同時にapt-getが実行され
      # dpkgロックの競合(exit code 100)でどちらかが失敗することがある。
      # 専用のロックファイルでapt-get呼び出し自体を直列化する
      # (apt自身が使う/var/lib/apt/lists/lockを外側からもflockすると、
      # apt-get内部のロック取得と二重にロックしようとしてデッドロックするため
      # 別のロックファイルを使う)。
      flock /tmp/wireguard-module-apt.lock -c "apt-get update -y"
      flock /tmp/wireguard-module-apt.lock -c "apt-get install -y wireguard"

      install -d -m 700 /etc/wireguard

      if [ ! -f /etc/wireguard/privatekey ]; then
        wg genkey > /etc/wireguard/privatekey
        wg pubkey < /etc/wireguard/privatekey > /etc/wireguard/publickey
      fi
      chmod 600 /etc/wireguard/privatekey

      private_key=$(cat /etc/wireguard/privatekey)

      cat > /etc/wireguard/${var.wireguard_interface}.conf <<WG_EOF
      [Interface]
      Address = ${var.wireguard_address}
      PrivateKey = $private_key
${local.postup_lines}

      [Peer]
      PublicKey = ${var.server_public_key}
      AllowedIPs = ${join(", ", var.server_allowed_ips)}
      Endpoint = ${var.server_endpoint}
      PersistentKeepalive = ${var.persistent_keepalive}
      WG_EOF
      chmod 600 /etc/wireguard/${var.wireguard_interface}.conf

      systemctl enable wg-quick@${var.wireguard_interface}
      systemctl restart wg-quick@${var.wireguard_interface}

      echo "=== WireGuard status ==="
      wg show ${var.wireguard_interface}
      echo "=== Public key ==="
      cat /etc/wireguard/publickey
    SCRIPT
    destination = "/tmp/wireguard-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash /tmp/wireguard-setup.sh && rm -f /tmp/wireguard-setup.sh",
    ]
  }
}
