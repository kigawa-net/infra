# ノードの NIC に、固定のアドレスとデフォルト経路を足す(networkd のドロップイン。kigawa-net/infra#317、files/static-network.sh)。
#
# k8s-worker1 は、DHCP が付けていた 192.168.1.228 とデフォルト経路が、DHCP の停止で消え、kubelet が API サーバーに届かず NotReady になった。
# DHCP に依存しないよう、固定にする。netplan の YAML は触らない(/etc/systemd/network/10-netplan-<NIC>.network.d/ にドロップインを置く)。
# 冪等。反映の後に、アドレスと経路が付いたことを確認し、付かなければ、戻して失敗する。

locals {
  script = file("${path.module}/files/static-network.sh")
}

resource "null_resource" "static_network" {
  triggers = {
    host        = var.host
    interface   = var.interface
    address     = var.address
    gateway     = var.gateway
    script_hash = sha256(local.script)
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.script
    destination = "/tmp/static-network.sh"
  }

  # remote-exec の inline は dash で動くので、シバン付きのスクリプトを、bash で明示的に実行する(他のモジュールと同じ)。
  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S env IFACE='${var.interface}' ADDRESS='${var.address}' GATEWAY='${var.gateway}' bash /tmp/static-network.sh; rc=$?; rm -f /tmp/static-network.sh; exit $rc",
    ]
  }
}
