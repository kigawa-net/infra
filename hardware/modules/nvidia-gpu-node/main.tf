# NVIDIA ドライバを入れる(kigawa-net/infra#302)。
#
# - Container Toolkit と containerd の設定は、既定では入れない。クラスタの gpu-operator(kigawa-net-k8s の apps/gpu-operator-app.yml、
#   toolkit.enabled=true)の Toolkit DaemonSet が containerd を設定するため、ここでも入れると二重になって衝突する。
#   gpu-operator を使わないノードだけ install_container_toolkit=true にする。
# - nvidia ランタイムは「既定にしない」。GPU を使う Pod が RuntimeClass `nvidia` で選ぶ。
# - drain と再起動は、このモジュールでは行わない(稼働中のノードを Terraform が勝手に止めないため)。
#   手順: kubectl drain → enabled=true で apply → 再起動 → nvidia-smi 確認 → kubectl uncordon。
# - 冪等。ドライバが入っていれば再インストールせず、パッケージは apt-mark hold で固定する。
locals {
  setup_script = <<-SCRIPT
    #!/bin/bash
    set -eo pipefail
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y
    # `apt-cache policy ... | grep -q` は、pipefail のもとで grep の早期終了により apt-cache が SIGPIPE(141)になり、
    # パッケージがあっても失敗する。いったん変数に取ってから判定する。
    candidate=$(apt-cache policy ${var.driver_package} | awk '/Candidate:/ {print $2}')
    if [ -z "$candidate" ] || [ "$candidate" = "(none)" ]; then
      echo "ERROR: ${var.driver_package} が apt に無い。driver_package を見直す" >&2
      exit 1
    fi

    # hold 済みのパッケージを install し直すと、新しい版が出た後の再実行で「held packages」で止まる。入っていれば飛ばす
    if ! dpkg -s ${var.driver_package} >/dev/null 2>&1; then
      apt-get install -y ${var.driver_package}
    fi
    apt-mark hold ${var.driver_package}

    %{if var.install_container_toolkit~}
    if [ ! -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg ]; then
      apt-get install -y curl gpg
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    fi
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -y
    if ! dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
      apt-get install -y nvidia-container-toolkit
    fi
    apt-mark hold nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1

    # --set-as-default は付けない(RuntimeClass nvidia で選ぶ)
    nvidia-ctk runtime configure --runtime=containerd
    systemctl restart containerd
    %{endif~}

    if nvidia-smi >/dev/null 2>&1; then
      nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv
    else
      echo "=== ドライバは導入済み。有効にするには再起動が必要(nvidia-smi は再起動後に確認) ==="
    fi
    SCRIPT
}

resource "null_resource" "nvidia_gpu_node" {
  count = var.enabled ? 1 : 0

  triggers = {
    host              = var.host
    driver_package    = var.driver_package
    install_toolkit   = tostring(var.install_container_toolkit)
    setup_script_hash = sha256(local.setup_script)
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.setup_script
    destination = "/tmp/nvidia-gpu-node-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash /tmp/nvidia-gpu-node-setup.sh && rm -f /tmp/nvidia-gpu-node-setup.sh",
    ]
  }
}
