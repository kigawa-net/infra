locals {
  # kresd 5.x (the version shipped by pkg.labs.nic.cz for Ubuntu noble) uses the
  # legacy Lua configuration format, not the newer declarative YAML config.
  kresd_conf = <<-CONF
-- Managed by Terraform (hardware/modules/knot-resolver) -- do not edit by hand

-- systemd-resolved already holds specific loopback addresses (127.0.0.53,
-- 127.0.0.54) on port 53; the kernel refuses a wildcard 0.0.0.0 bind on the
-- same port once a more specific address is bound there, so listen on
-- explicit addresses instead of 0.0.0.0.
net.listen('127.0.0.1', 53, { kind = 'dns' })
net.listen('${var.host}', 53, { kind = 'dns' })
net.listen('127.0.0.1', 853, { kind = 'tls' })
%{~if var.dns_vip != ""}
net.listen('${var.dns_vip}', 53, { kind = 'dns' })
%{~endif}

modules = { 'policy' }

cache.size = ${var.cache_size_mb} * MB
cache.storage = 'lmdb:///var/cache/knot-resolver'

-- STUB (not FORWARD): these are private/unsigned internal zones, so skip
-- local DNSSEC validation and trust the upstream directly.
policy.add(policy.suffix(policy.STUB({'${var.coredns_ip}'}), {todname('cluster.local.')}))
%{for d in var.internal_domains}
policy.add(policy.suffix(policy.STUB({'${var.internal_dns_ip}'}), {todname('${d}.')}))
%{endfor}
policy.add(policy.all(policy.FORWARD({'1.1.1.1', '1.0.0.1', '8.8.8.8', '8.8.4.4'})))
CONF
}

locals {
  install_script = <<-SCRIPT
    #!/bin/bash
    set -euo pipefail
    LOG=/tmp/knot-resolver-install.log
    exec > >(tee -a "$LOG") 2>&1

    export DEBIAN_FRONTEND=noninteractive

    echo "=== Removing stale knot-resolver static pod manifest (broken container image) ==="
    rm -f /etc/kubernetes/manifests/knot-resolver.yaml

    echo "=== apt-get install curl gpg ==="
    apt-get install -y curl gpg

    echo "=== Fetching GPG key ==="
    mkdir -p /etc/apt/keyrings
    curl -fsSL \
      https://keys.openpgp.org/vks/v1/by-fingerprint/CC57AC4EDA32021608543664D959241751179EC7 \
      | gpg --batch --dearmor --yes \
          -o /etc/apt/keyrings/labs-nic-cz-knot-resolver.gpg

    echo "=== Adding apt source ==="
    . /etc/os-release
    echo "deb [signed-by=/etc/apt/keyrings/labs-nic-cz-knot-resolver.gpg] \
https://pkg.labs.nic.cz/knot-resolver $${VERSION_CODENAME} main" \
      > /etc/apt/sources.list.d/labs-nic-cz-knot-resolver.list
    cat /etc/apt/sources.list.d/labs-nic-cz-knot-resolver.list

    echo "=== apt-get update ==="
    apt-get update

    echo "=== Masking native knot.service before install (authoritative DNS already runs as a container on 127.0.0.1:5353; the knot package's postinst tries to (re)start it and fails otherwise, which aborts dpkg configuration) ==="
    systemctl mask knot.service

    echo "=== Installing knot-resolver ==="
    apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
      install -y --allow-change-held-packages knot-resolver

    echo "=== Finishing any pending dpkg configuration ==="
    dpkg --configure -a

    echo "=== Creating directories ==="
    mkdir -p /var/cache/knot-resolver /var/run/knot-resolver
    chown -R knot-resolver: /var/cache/knot-resolver /var/run/knot-resolver \
      2>/dev/null \
      || chown -R _knot-resolver: /var/cache/knot-resolver /var/run/knot-resolver

    echo "=== Done ==="
  SCRIPT
}

locals {
  # sudo_password(sensitive)を埋め込む前の、素のコマンド本体だけを保持する。
  # provisioner "remote-exec" の inline を直接編集しても null_resource の
  # triggers には反映されず再実行がスキップされてしまう(実際に発生した不具合:
  # systemctl restart → stop/キャッシュ削除/start に変更したのに、triggersに
  # 変更を検知する項目が無かったためTerraformが差分なしと判断し、一度も
  # 実行されなかった)。このリストをハッシュ化してtriggersに含めることで、
  # 手順を変更するたびに確実に再実行させる。
  remote_exec_steps = [
    "bash /tmp/knot-resolver-install.sh",
    "cp /tmp/kresd.conf /etc/knot-resolver/kresd.conf",
    "systemctl enable --now kresd@1.service",
    # cache.storage は lmdb (ディスク永続化) のため、単純な systemctl restart
    # だけではキャッシュが消えず、ゾーンを更新してもレコードのTTL(最大24時間)
    # いっぱい古い応答を返し続けてしまう。stop → キャッシュディレクトリの
    # 中身を削除 → start の順で確実にフラッシュする。
    "systemctl stop kresd@1.service",
    "rm -rf /var/cache/knot-resolver/*",
    "systemctl start kresd@1.service",
    "rm -f /tmp/kresd.conf /tmp/knot-resolver-install.sh",
  ]
}

resource "null_resource" "knot_resolver" {
  triggers = {
    host                 = var.host
    zones_reload_trigger = var.zones_reload_trigger
    kresd_conf           = local.kresd_conf
    install_script       = sha256(local.install_script)
    remote_exec_steps    = sha256(join("\n", local.remote_exec_steps))
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.install_script
    destination = "/tmp/knot-resolver-install.sh"
  }

  provisioner "file" {
    content     = local.kresd_conf
    destination = "/tmp/kresd.conf"
  }

  provisioner "remote-exec" {
    inline = [for step in local.remote_exec_steps : "echo '${var.sudo_password}' | sudo -S ${step}"]
  }
}
