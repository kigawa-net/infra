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

  # remote-execのinline配列はシバンなしでscriptを転送されるため、SSHのexecがENOEXECで
  # /bin/sh(dash)にフォールバックしてしまい、bash専用の`pipefail`が構文エラーになる。
  # wireguard/k8s-control-planeモジュールと同様に、シバン付きスクリプトを転送して
  # `sudo bash <script>`で明示的にbash実行することでこれを回避する。
  setup_script = <<-SCRIPT
    #!/bin/bash
    set -eo pipefail
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    id node_exporter &>/dev/null || useradd --no-create-home --shell /bin/false node_exporter

    cd /tmp
    curl -fsSL https://github.com/prometheus/node_exporter/releases/download/v${var.node_exporter_version}/node_exporter-${var.node_exporter_version}.linux-amd64.tar.gz | tar xz
    install -m 755 node_exporter-${var.node_exporter_version}.linux-amd64/node_exporter /usr/local/bin/node_exporter
    rm -rf node_exporter-${var.node_exporter_version}.linux-amd64

    cp /tmp/node_exporter.service /etc/systemd/system/node_exporter.service
    rm -f /tmp/node_exporter.service

    systemctl daemon-reload
    systemctl enable --now node_exporter
    systemctl restart node_exporter
    SCRIPT
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

  provisioner "file" {
    content     = local.setup_script
    destination = "/tmp/node_exporter-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash /tmp/node_exporter-setup.sh && rm -f /tmp/node_exporter-setup.sh",
    ]
  }
}
