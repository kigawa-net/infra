locals {
  bgp_loopback_ip = "127.0.0.2"

  peer_blocks = join("\n\n", [
    for idx, peer_ip in var.bgp_peers :
    "protocol bgp peer${idx} {\n  local ${var.bgp_router_id} as ${var.bgp_local_as};\n  neighbor ${peer_ip} as ${var.bgp_local_as};\n  ipv4 {\n    import all;\n    export filter {\n      # ionos自身のWireGuardハブアドレス(172.31.254.2/32)は各ノードが\n      # 自分自身のkernel-connected経路で直接解決すべきローカルなnext-hop\n      # 解決用ルートであり、他ノードへ再広告するとより優先されてしまい、\n      # 本来の直結経路より劣ったパス経由でルーティングされてしまう\n      # (WireGuardの送信元スプーフィング防止で応答が破棄される原因になった)。\n      if net = 172.31.254.2/32 then reject;\n      # next-hop-self: eBGP由来のルート(例: k8s4がionosから学習した\n      # 172.31.254.0/24)をiBGPでそのまま転送すると、next-hopがeBGP\n      # ピアの生アドレス(172.31.254.2)のままになり、受信側ノードが\n      # それを自分自身のローカルなionos向けwg1トンネル経由で再帰的に\n      # 解決しようとしてしまう。しかしそのトンネルのAllowedIPsは\n      # ionos自身(172.31.254.2/32)にしか対応しておらず、soichiro等の\n      # 他ピア宛パケットはWireGuard自体に拒否される。next-hopを常に\n      # 自ノードの実IPへ書き換えることで、受信側は実ネットワーク\n      # (BGPピアリングに使っている実IP)経由で正しく経路解決できる。\n      bgp_next_hop = ${var.bgp_router_id};\n      accept;\n    };\n  };\n}"
  ])

  external_peer_blocks = join("\n\n", [
    for idx, peer in var.external_bgp_peers :
    "protocol bgp external${idx} {\n  local ${peer.local_ip} as ${peer.local_as};\n  neighbor ${peer.neighbor_ip} as ${peer.neighbor_as};\n  ipv4 {\n    import filter {\n${join("\n", [for prefix in peer.import_prefixes : "      if net = ${prefix} then accept;"])}\n      reject;\n    };\n    export filter {\n${join("\n", [for prefix in peer.export_prefixes : "      if net = ${prefix} then accept;"])}\n      reject;\n    };\n  };\n}"
  ])

  bird_conf = <<-CONF
log syslog all;

router id ${var.bgp_router_id};

protocol device {}

protocol direct {
  ipv4;
}

protocol kernel {
  ipv4 {
    export filter {
      # 172.31.254.2/32(ionos自身)はBIRDのnext-hop解決専用のstatic route
      # (下記protocol static ionos_nexthop_helper)であり、カーネルの
      # ルーティングテーブルへはエクスポートしない。エクスポートすると
      # より詳細な/32ルートとして一般のIPトラフィックの転送先にも使われて
      # しまい、k8s4経由の正しい中継パス(BGP学習した/30・/24)より優先
      # されて応答パケットが送信元スプーフィング防止で破棄される問題が起きる。
      if net = 172.31.254.2/32 then reject;
      accept;
    };
    import all;
  };
  learn;
  persist;
}
%{~if var.ionos_nexthop_helper_interface != ""}

protocol static ionos_nexthop_helper {
  ipv4;
  route 172.31.254.2/32 via "${var.ionos_nexthop_helper_interface}";
}
%{~endif}

${local.peer_blocks}
%{~if length(var.advertised_vips) > 0}

protocol static local_vips {
  ipv4;
%{~for vip in var.advertised_vips}
  route ${vip}/32 blackhole;
%{~endfor}
}
%{~endif}

${local.external_peer_blocks}

protocol bgp kube_vip {
  local ${local.bgp_loopback_ip} as ${var.bgp_local_as};
  neighbor 127.0.0.1 as ${var.kube_vip_as};
  multihop;
  passive on;
  ipv4 {
    import filter {
      bgp_next_hop = ${var.bgp_router_id};
      accept;
    };
    export none;
  };
}
CONF

  # bird.confの内容が変わったときにpodを再起動させるためアノテーションにハッシュを埋め込む
  pod_manifest = <<-POD
apiVersion: v1
kind: Pod
metadata:
  name: bird
  namespace: kube-system
  annotations:
    config-hash: "${sha256(local.bird_conf)}"
spec:
  hostNetwork: true
  priorityClassName: system-node-critical
  containers:
  - name: bird
    image: ${var.bird_image}
    command: ["bird", "-f", "-c", "/etc/bird/bird.conf"]
    securityContext:
      capabilities:
        add:
        - NET_ADMIN
        - NET_RAW
    volumeMounts:
    - name: bird-config
      mountPath: /etc/bird
      readOnly: true
    - name: bird-run
      mountPath: /var/run/bird
  volumes:
  - name: bird-config
    hostPath:
      path: /etc/bird
      type: DirectoryOrCreate
  - name: bird-run
    hostPath:
      path: /var/run/bird
      type: DirectoryOrCreate
POD
}

resource "null_resource" "bird" {
  triggers = {
    host            = var.host
    bird_conf       = local.bird_conf
    pod_yaml        = local.pod_manifest
    bgp_loopback_ip = local.bgp_loopback_ip
    advertised_vips = join(",", var.advertised_vips)
    external_peers  = jsonencode(var.external_bgp_peers)
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S mkdir -p /etc/bird /var/run/bird",
      "echo '${var.sudo_password}' | sudo -S ip addr del 127.0.0.100/32 dev lo 2>/dev/null || true",
      "echo '${var.sudo_password}' | sudo -S rm -f /etc/netplan/99-bgp-loopback.yaml",
    ]
  }

  provisioner "file" {
    content     = local.bird_conf
    destination = "/tmp/bird.conf"
  }

  provisioner "file" {
    content     = local.pod_manifest
    destination = "/tmp/bird-pod.yaml"
  }

  provisioner "file" {
    content     = <<-SCRIPT
      #!/bin/bash
      %{~for vip in var.advertised_vips}
      ip addr add ${vip}/32 dev lo 2>/dev/null || true
      %{~endfor}
      SCRIPT
    destination = "/tmp/local-vip-setup.sh"
  }

  provisioner "file" {
    content     = <<-UNIT
      [Unit]
      Description=Local VIP addresses on loopback
      After=network.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/bin/bash /usr/local/bin/local-vip-setup.sh

      [Install]
      WantedBy=multi-user.target
      UNIT
    destination = "/tmp/local-vip.service"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S cp /tmp/bird.conf /etc/bird/bird.conf",
      "echo '${var.sudo_password}' | sudo -S cp /tmp/bird-pod.yaml /etc/kubernetes/manifests/bird.yaml",
      "echo '${var.sudo_password}' | sudo -S cp /tmp/local-vip-setup.sh /usr/local/bin/local-vip-setup.sh",
      "echo '${var.sudo_password}' | sudo -S chmod +x /usr/local/bin/local-vip-setup.sh",
      "echo '${var.sudo_password}' | sudo -S cp /tmp/local-vip.service /etc/systemd/system/local-vip.service",
      "echo '${var.sudo_password}' | sudo -S systemctl daemon-reload",
      "echo '${var.sudo_password}' | sudo -S systemctl enable --now local-vip.service",
      "rm -f /tmp/bird.conf /tmp/bird-pod.yaml /tmp/local-vip-setup.sh /tmp/local-vip.service",
    ]
  }
}
