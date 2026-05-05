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

  pod_manifest = <<-POD
apiVersion: v1
kind: Pod
metadata:
  name: knot
  namespace: kube-system
  annotations:
    config-hash: "${sha256(local.knot_conf)}"
spec:
  hostNetwork: true
  priorityClassName: system-node-critical
  containers:
  - name: knot
    image: ${var.knot_image}
    command: ["knotd", "-c", "/etc/knot/knot.conf"]
    securityContext:
      runAsUser: 0
      capabilities:
        add:
        - NET_BIND_SERVICE
    volumeMounts:
    - name: knot-config
      mountPath: /etc/knot
      readOnly: true
    - name: knot-data
      mountPath: /var/lib/knot
    - name: knot-run
      mountPath: /run/knot
  volumes:
  - name: knot-config
    hostPath:
      path: /etc/knot
      type: DirectoryOrCreate
  - name: knot-data
    hostPath:
      path: /var/lib/knot
      type: DirectoryOrCreate
  - name: knot-run
    hostPath:
      path: /run/knot
      type: DirectoryOrCreate
POD
}

resource "null_resource" "knot" {
  triggers = {
    host      = var.host
    knot_conf = local.knot_conf
    zones     = jsonencode(var.zones)
    pod_yaml  = local.pod_manifest
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "remote-exec" {
    inline = concat(
      ["echo '${var.sudo_password}' | sudo -S mkdir -p /etc/knot /var/lib/knot /run/knot"],
      [for zone_name, zone_content in var.zones :
        "echo '${var.sudo_password}' | sudo -S bash -c 'echo ${base64encode(zone_content)} | base64 -d > /var/lib/knot/${zone_name}.zone'"
      ]
    )
  }

  provisioner "file" {
    content     = local.knot_conf
    destination = "/tmp/knot.conf"
  }

  provisioner "file" {
    content     = local.pod_manifest
    destination = "/tmp/knot-pod.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S cp /tmp/knot.conf /etc/knot/knot.conf",
      "echo '${var.sudo_password}' | sudo -S cp /tmp/knot-pod.yaml /etc/kubernetes/manifests/knot.yaml",
      "rm -f /tmp/knot.conf /tmp/knot-pod.yaml",
    ]
  }
}
