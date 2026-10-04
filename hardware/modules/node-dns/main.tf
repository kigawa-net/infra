locals {
  conf = <<-CONF
    # Terraform(hardware/modules/node-dns)が管理。内部ドメインを kresd に向ける。
    # 2026-10-04: 各ノードは、自宅ルーター(192.168.1.1)で k8s.kigawa.net を引いていた。ルーターの dnsmasq は、
    # 上流を 192.168.1.20(k8s2)にしていて、k8s2 が止まると引けなくなり、kubelet が API に繋がらず、全ノードが
    # NotReady になった(kigawa-net/infra の障害対応)。
    [Resolve]
    DNS=${join(" ", var.dns_servers)}
    Domains=${join(" ", [for d in var.routing_domains : "~${d}"])}
  CONF

  apply_script = <<-SCRIPT
    #!/bin/bash
    set -u
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    CONF=/etc/systemd/resolved.conf.d/10-internal-dns.conf
    BACKUP=/etc/systemd/resolved.conf.d/10-internal-dns.conf.prev

    install -d -m 755 /etc/systemd/resolved.conf.d
    if [ -f "$CONF" ]; then cp -a "$CONF" "$BACKUP"; else rm -f "$BACKUP"; fi
    install -m 644 /tmp/10-internal-dns.conf "$CONF"
    systemctl restart systemd-resolved
    sleep 2

    # 検証: 内部のアドレスに解決されること。解決されなければ、元に戻して失敗にする
    ip=$(getent ahostsv4 ${var.verify_name} 2>/dev/null | awk 'NR==1{print $1}')
    echo "verify: ${var.verify_name} -> $${ip:-<解決できない>}"
    case "$ip" in
      ${var.verify_prefix}*) echo "OK" ;;
      *)
        echo "NG: 内部のアドレスに解決されないため、元に戻す" >&2
        if [ -f "$BACKUP" ]; then mv -f "$BACKUP" "$CONF"; else rm -f "$CONF"; fi
        systemctl restart systemd-resolved
        exit 1
        ;;
    esac
    rm -f "$BACKUP"
  SCRIPT
}

resource "null_resource" "node_dns" {
  triggers = {
    host         = var.host
    conf         = local.conf
    apply_script = sha256(local.apply_script)
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
    timeout     = "10m"
  }

  provisioner "file" {
    content     = local.conf
    destination = "/tmp/10-internal-dns.conf"
  }

  provisioner "file" {
    content     = local.apply_script
    destination = "/tmp/node-dns-apply.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash /tmp/node-dns-apply.sh",
      "rm -f /tmp/node-dns-apply.sh /tmp/10-internal-dns.conf",
    ]
  }
}
