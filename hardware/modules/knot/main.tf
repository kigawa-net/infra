locals {
  zone_blocks = length(var.zones) > 0 ? "zone:\n${join("\n", [for name, _ in var.zones : "  - domain: ${name}\n    file: /var/lib/knot/${name}.zone"])}" : ""

  knot_conf = <<-CONF
server:
    listen: "127.0.0.1@5353"

log:
  - target: stdout
    any: info

database:
    storage: "/var/lib/knot"

${local.zone_blocks}

${var.extra_config}
CONF
}

resource "null_resource" "knot" {
  triggers = {
    host      = var.host
    knot_conf = local.knot_conf
    # var.zones changes (e.g. editing hardware/zones/*.zone) previously went undetected:
    # the provisioners below that actually deploy zone files only run on resource
    # create/replace, and this trigger set had no reference to zone *content* at all.
    zones          = jsonencode(var.zones)
    script_version = "3"
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
    # デフォルトの5分だとk8s1(既知の低速ディスク問題)でapt-get等が
    # 間に合わずremote-execがタイムアウトする(失敗ログが毎回5m46-47秒
    # で揃っていたことから確認)ため延長する
    timeout = "20m"
  }

  # 同一ホスト上の他モジュール(control_plane/wireguard/keepalived等)のapt-getとの
  # 並列実行やOSのunattended-upgradesとの競合でdpkgロックが取れず失敗することが
  # ある。事前にロックが空くのを待つだけではチェック直後に別プロセスが取って
  # しまうTOCTOU競合があるため、失敗した場合はリトライする
  # (hardware/modules/wireguardと同じ対応)。
  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash -c 'wait_lock() { for i in $(seq 1 60); do fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1 || return 0; sleep 5; done; return 1; }; for a in $(seq 1 20); do wait_lock; apt-get update && apt-get install -y knot && break; sleep 5; done'",
      "echo '${var.sudo_password}' | sudo -S mkdir -p /var/lib/knot",
    ]
  }

  provisioner "file" {
    content     = local.knot_conf
    destination = "/tmp/knot.conf"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S cp /tmp/knot.conf /etc/knot/knot.conf",
    ]
  }

  # Deploy zone files with base64 encoding
  provisioner "remote-exec" {
    inline = concat(
      ["echo 'Deploying zone files...'"],
      [for zone_name, zone_content in var.zones :
        "echo '${var.sudo_password}' | sudo -S bash -c 'echo ${base64encode(zone_content)} | base64 -d > /var/lib/knot/${zone_name}.zone'"
      ]
    )
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S chown -R knot:knot /var/lib/knot",
      "echo '${var.sudo_password}' | sudo -S systemctl enable knot",
      "echo '${var.sudo_password}' | sudo -S systemctl restart knot",
      "echo 'Knot configured and started'",
    ]
  }

  provisioner "remote-exec" {
    inline = [
      "rm -f /tmp/knot.conf",
    ]
  }
}
