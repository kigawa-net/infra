locals {
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
    host      = var.host
    bird_conf = local.bird_conf
    pod_yaml  = local.pod_manifest
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

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S cp /tmp/bird.conf /etc/bird/bird.conf",
      "echo '${var.sudo_password}' | sudo -S cp /tmp/bird-pod.yaml /etc/kubernetes/manifests/bird.yaml",
      "rm -f /tmp/bird.conf /tmp/bird-pod.yaml",
    ]
  }
}
