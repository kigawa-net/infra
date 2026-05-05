locals {
  bgp_loopback_ip = "127.0.0.2"

  peer_blocks = join("\n\n", [
    for idx, peer_ip in var.bgp_peers :
    "protocol bgp peer${idx} {\n  local ${var.bgp_router_id} as ${var.bgp_local_as};\n  neighbor ${peer_ip} as ${var.bgp_local_as};\n  ipv4 {\n    import all;\n    export all;\n  };\n}"
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
    export all;
    import all;
  };
  learn;
  persist;
}

${local.peer_blocks}
%{~ if length(var.advertised_vips) > 0 }

protocol static local_vips {
  ipv4;
%{~ for vip in var.advertised_vips }
  route ${vip}/32 blackhole;
%{~ endfor }
}
%{~ endif }

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
      %{~ for vip in var.advertised_vips }
      ip addr add ${vip}/32 dev lo 2>/dev/null || true
      %{~ endfor }
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
