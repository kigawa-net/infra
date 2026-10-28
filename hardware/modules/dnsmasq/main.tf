locals {
  # dnsmasq config: server=/domain/IP format (no port support in domain-specific rules)
  # For Knot on non-standard port, use upstream DNS with address#port
  dnsmasq_conf = join("", [
    "port=53\n",
    "bind-interfaces\n",
    "listen-address=0.0.0.0\n",
    "no-resolv\n",
    "\n",
    "server=/cluster.local/${var.coredns_ip}\n",
    join("", [for d in var.internal_domains : "server=/${d}/127.0.0.1#5353\n"]),
    "\n",
    "server=8.8.8.8\n",
    "server=8.8.4.4\n",
    "server=1.1.1.1\n",
    "server=1.0.0.1\n",
    "\n",
    "cache-size=${var.cache_size_mb}\n",
    "log-queries\n",
    "log-facility=-\n",
  ])

  pod_manifest = <<-POD
apiVersion: v1
kind: Pod
metadata:
  name: dnsmasq
  namespace: kube-system
  annotations:
    config-hash: "${sha256(local.dnsmasq_conf)}"
spec:
  hostNetwork: true
  priorityClassName: system-node-critical
  containers:
  - name: dnsmasq
    image: jpillora/dnsmasq:latest
    args:
      - -C
      - /etc/dnsmasq/dnsmasq.conf
      - -d
    securityContext:
      capabilities:
        add:
        - NET_BIND_SERVICE
    volumeMounts:
    - name: dnsmasq-config
      mountPath: /etc/dnsmasq
      readOnly: true
  volumes:
  - name: dnsmasq-config
    hostPath:
      path: /etc/dnsmasq
      type: DirectoryOrCreate
POD
}

resource "null_resource" "dnsmasq" {
  triggers = {
    host           = var.host
    dnsmasq_conf   = local.dnsmasq_conf
    pod_yaml       = local.pod_manifest
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S mkdir -p /etc/kubernetes/manifests /etc/dnsmasq",
    ]
  }

  provisioner "file" {
    content     = local.dnsmasq_conf
    destination = "/tmp/dnsmasq.conf"
  }

  provisioner "file" {
    content     = local.pod_manifest
    destination = "/tmp/dnsmasq-pod.yaml"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S cp /tmp/dnsmasq.conf /etc/dnsmasq/dnsmasq.conf",
      "echo '${var.sudo_password}' | sudo -S cp /tmp/dnsmasq-pod.yaml /etc/kubernetes/manifests/dnsmasq.yaml",
      "rm -f /tmp/dnsmasq.conf /tmp/dnsmasq-pod.yaml",
    ]
  }
}
