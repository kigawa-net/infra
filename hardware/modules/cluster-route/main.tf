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

locals {
  # 2026-10-03(issue #193): 経路が失われたまま誰も気付かず、CoreDNSの
  # 10.0.0.53向けforwardが約3時間タイムアウトし続けた。原因を特定できていないため、
  # 原因に依存しない対策として、冪等な `ip route replace` を1分ごとに再実行し、
  # 経路が何らかの理由で消えても自動復旧させる。
  route_timer = <<-TIMER
    [Unit]
    Description=Periodically re-apply static route to cluster LAN (${var.destination_cidr})

    [Timer]
    OnBootSec=30s
    OnUnitActiveSec=60s
    AccuracySec=5s

    [Install]
    WantedBy=timers.target
  TIMER
}

resource "null_resource" "cluster_route" {
  triggers = {
    host              = var.host
    destination_cidr  = var.destination_cidr
    gateways          = join(",", var.gateways)
    route_script_hash = sha256(local.route_script)
    timer_hash        = sha256(local.route_timer)
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
      ExecStart=/usr/local/bin/cluster-route.sh

      [Install]
      WantedBy=multi-user.target
    UNIT
    destination = "/tmp/cluster-route.service"
  }

  provisioner "file" {
    content     = local.route_timer
    destination = "/tmp/cluster-route.timer"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash -c 'install -m 755 /tmp/cluster-route.sh /usr/local/bin/cluster-route.sh && install -m 644 /tmp/cluster-route.service /etc/systemd/system/cluster-route.service && install -m 644 /tmp/cluster-route.timer /etc/systemd/system/cluster-route.timer && systemctl daemon-reload && systemctl enable cluster-route.service && systemctl enable --now cluster-route.timer && systemctl start cluster-route.service && rm -f /tmp/cluster-route.sh /tmp/cluster-route.service /tmp/cluster-route.timer'",
    ]
  }
}
