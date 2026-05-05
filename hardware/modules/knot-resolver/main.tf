locals {
  kresd_conf = <<-CONF
workers: 1

logging:
  level: notice

network:
  listen:
    - interface: "0.0.0.0@53"
    - interface: "0.0.0.0@853"
      kind: dot

cache:
  size-max: ${var.cache_size_mb}M
  storage: /var/cache/knot-resolver

forward:
  - subtree: "cluster.local."
    servers:
      - "${var.coredns_ip}"

%{~ for d in var.internal_domains ~}
  - subtree: "${d}."
    servers:
      - "${var.internal_dns_ip}"

%{~ endfor ~}
  - subtree: "."
    servers:
      - address: "8.8.8.8"
        transport: tls
        hostname: "dns.google"
      - address: "8.8.4.4"
        transport: tls
        hostname: "dns.google"
      - address: "1.1.1.1"
        transport: tls
        hostname: "cloudflare-dns.com"
      - address: "1.0.0.1"
        transport: tls
        hostname: "cloudflare-dns.com"
CONF

  pod_manifest = <<-POD
apiVersion: v1
kind: Pod
metadata:
  name: knot-resolver
  namespace: kube-system
  annotations:
    config-hash: "${sha256(local.kresd_conf)}"
spec:
  hostNetwork: true
  priorityClassName: system-node-critical
  containers:
  - name: kresd
    image: ${var.kresd_image}
    args: ["-c", "/etc/knot-resolver/kresd.conf"]
    securityContext:
      capabilities:
        add:
        - NET_BIND_SERVICE
    volumeMounts:
    - name: kresd-config
      mountPath: /etc/knot-resolver
      readOnly: true
    - name: kresd-cache
      mountPath: /var/cache/knot-resolver
    - name: kresd-run
      mountPath: /var/run/knot-resolver
  volumes:
  - name: kresd-config
    hostPath:
      path: /etc/knot-resolver
      type: DirectoryOrCreate
  - name: kresd-cache
    hostPath:
      path: /var/cache/knot-resolver
      type: DirectoryOrCreate
  - name: kresd-run
    hostPath:
      path: /var/run/knot-resolver
      type: DirectoryOrCreate
POD
}

resource "null_resource" "knot_resolver" {
  triggers = {
    host       = var.host
    kresd_conf = local.kresd_conf
    pod_yaml   = local.pod_manifest
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S mkdir -p /etc/knot-resolver /var/cache/knot-resolver /var/run/knot-resolver",
    ]
  }

  provisioner "file" {
    content     = local.kresd_conf
    destination = "/tmp/kresd.conf"
  }

  provisioner "file" {
    content     = local.pod_manifest
    destination = "/tmp/knot-resolver-pod.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S cp /tmp/kresd.conf /etc/knot-resolver/kresd.conf",
      "echo '${var.sudo_password}' | sudo -S cp /tmp/knot-resolver-pod.yaml /etc/kubernetes/manifests/knot-resolver.yaml",
      "rm -f /tmp/kresd.conf /tmp/knot-resolver-pod.yaml",
    ]
  }
}
