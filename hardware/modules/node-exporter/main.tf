locals {
  service_unit = <<-UNIT
    [Unit]
    Description=Prometheus Node Exporter
    After=network.target

    [Service]
    User=node_exporter
    Group=node_exporter
    Type=simple
    ExecStart=/usr/local/bin/node_exporter --web.listen-address=${var.listen_address}
    Restart=on-failure

    [Install]
    WantedBy=multi-user.target
    UNIT
}

resource "null_resource" "node_exporter" {
  triggers = {
    host           = var.host
    version        = var.node_exporter_version
    listen_address = var.listen_address
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.service_unit
    destination = "/tmp/node_exporter.service"
  }

  provisioner "remote-exec" {
    inline = [
      "set -eo pipefail",
      "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
      "echo '${var.sudo_password}' | sudo -S id",

      # ユーザー作成（冪等）
      "echo '${var.sudo_password}' | sudo -S bash -c 'id node_exporter &>/dev/null || useradd --no-create-home --shell /bin/false node_exporter'",

      # バイナリインストール
      "echo '${var.sudo_password}' | sudo -S bash -c 'cd /tmp && curl -fsSL https://github.com/prometheus/node_exporter/releases/download/v${var.node_exporter_version}/node_exporter-${var.node_exporter_version}.linux-amd64.tar.gz | tar xz && install -m 755 node_exporter-${var.node_exporter_version}.linux-amd64/node_exporter /usr/local/bin/node_exporter && rm -rf node_exporter-${var.node_exporter_version}.linux-amd64'",

      # サービスファイル配置
      "echo '${var.sudo_password}' | sudo -S cp /tmp/node_exporter.service /etc/systemd/system/node_exporter.service",
      "rm -f /tmp/node_exporter.service",

      # 有効化・起動
      "echo '${var.sudo_password}' | sudo -S systemctl daemon-reload",
      "echo '${var.sudo_password}' | sudo -S systemctl enable --now node_exporter",
      "echo '${var.sudo_password}' | sudo -S systemctl restart node_exporter",
    ]
  }
}
