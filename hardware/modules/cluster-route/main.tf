locals {
  # 2026-09-23のインシデント(issue #154): workerノードはクラスタLAN(10.0.0.0/24)
  # 宛のトラフィックに対する具体的な経路を持たず、自宅LANのデフォルトゲートウェイ
  # (物理ルーター)に送出していた。しかし物理ルーターはこの宛先を知らず
  # ブラックホール化し、内部DNSリゾルバ(kresd, 10.0.0.53)等への到達性が
  # 失われていた。k8s1/k8s2/k8s4は自宅LAN側にもアドレスを持ちip_forward=1が
  # 有効なため、これらをnext-hopとする静的経路を追加し、物理ゲートウェイは
  # 経路が使えない場合の最後のフォールバックに留める。
  nexthops = join(" ", [for gw in var.gateways : "nexthop via ${gw} weight 1"])

  route_script = <<-SCRIPT
    #!/bin/bash
    set -eo pipefail
    ip route replace ${var.destination_cidr} ${local.nexthops}
  SCRIPT
}

resource "null_resource" "cluster_route" {
  triggers = {
    host              = var.host
    destination_cidr  = var.destination_cidr
    gateways          = join(",", var.gateways)
    route_script_hash = sha256(local.route_script)
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.route_script
    destination = "/tmp/cluster-route.sh"
  }

  provisioner "file" {
    content     = <<-UNIT
      [Unit]
      Description=Add static route to cluster LAN (${var.destination_cidr}) via control-plane nodes
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/local/bin/cluster-route.sh

      [Install]
      WantedBy=multi-user.target
    UNIT
    destination = "/tmp/cluster-route.service"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash -c 'install -m 755 /tmp/cluster-route.sh /usr/local/bin/cluster-route.sh && install -m 644 /tmp/cluster-route.service /etc/systemd/system/cluster-route.service && systemctl daemon-reload && systemctl enable --now cluster-route.service && rm -f /tmp/cluster-route.sh /tmp/cluster-route.service'",
    ]
  }
}
