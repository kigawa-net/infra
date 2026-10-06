locals {
  # 既存の VI_1。extra_instances を使わない呼び出しでは、この文字列が変わらない(再適用されない)ようにする。
  base_conf = <<-CONF
    vrrp_instance VI_1 {
        state ${var.state}
        interface ${var.interface}
        virtual_router_id ${var.virtual_router_id}
        priority ${var.priority}
        advert_int 1
        authentication {
            auth_type PASS
            auth_pass ${var.auth_pass}
        }
        virtual_ipaddress {
            ${var.virtual_ip}
        }
    }
    CONF

  # ヘルスチェック(IP 転送が有効で、BGP が :179 で待ち受け中)。BIRD でも FRR でも動く条件にしている。
  check_core_router_script = <<-SCRIPT
    #!/bin/bash
    [ "$(sysctl -n net.ipv4.ip_forward)" = "1" ] || exit 1
    ss -H -ltn 'sport = :179' | grep -q . || exit 1
    SCRIPT

  # vrrp_script を使うには enable_script_security が必要(無いと keepalived が SECURITY VIOLATION で拒否する)。
  # スクリプトは root 所有の 0755 で /etc/keepalived に置くので、script_user は root にする。
  extra_conf = length(var.extra_instances) == 0 ? "" : <<-CONF
    global_defs {
        enable_script_security
        script_user root
    }

    vrrp_script chk_core_router {
        script "/etc/keepalived/check-core-router.sh"
        interval 2
        fall 2
        rise 2
        weight -30
    }
    %{~for inst in var.extra_instances}
    vrrp_instance ${inst.name} {
        state ${inst.state}
        interface ${var.interface}
        virtual_router_id ${inst.virtual_router_id}
        priority ${inst.priority}
        advert_int 1
        authentication {
            auth_type PASS
            auth_pass ${var.auth_pass}
        }
        virtual_ipaddress {
            ${inst.virtual_ip}
        }
    %{~if inst.check_core_router}
        track_script {
            chk_core_router
        }
    %{~endif}
    }
    %{~endfor}
    CONF

  keepalived_conf = "${local.base_conf}${local.extra_conf}"
}

resource "null_resource" "keepalived" {
  # extra_instances を使わない呼び出しでは、triggers を従来と同じにする(再適用されない)。
  triggers = merge(
    {
      host           = var.host
      conf_hash      = sha256(local.keepalived_conf)
      script_version = "3"
    },
    length(var.extra_instances) > 0 ? { check_hash = sha256(local.check_core_router_script) } : {}
  )

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.keepalived_conf
    destination = "/tmp/keepalived.conf"
  }

  provisioner "file" {
    content     = local.check_core_router_script
    destination = "/tmp/check-core-router.sh"
  }

  provisioner "remote-exec" {
    # 同一ホスト上で複数のnull_resourceのapt-getが並列実行される
    # (module.control_plane/module.wireguard/module.keepalived等)ことに加え、
    # OSのunattended-upgradesも不定期にdpkgロックを握るため、apt-get呼び出しの
    # 前にロックが空くまで待つ。事前チェックだけではチェック直後に別プロセスが
    # 取ってしまうTOCTOU競合があるため、失敗した場合はリトライする
    # (hardware/modules/wireguardと同じ対応)。
    inline = concat(
      [
        "echo '${var.sudo_password}' | sudo -S bash -c 'wait_lock() { for i in $(seq 1 60); do fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1 || return 0; sleep 5; done; return 1; }; for a in $(seq 1 20); do wait_lock; DEBIAN_FRONTEND=noninteractive apt-get update -y && break; sleep 5; done'",
        "echo '${var.sudo_password}' | sudo -S bash -c 'wait_lock() { for i in $(seq 1 60); do fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1 || return 0; sleep 5; done; return 1; }; for a in $(seq 1 20); do wait_lock; DEBIAN_FRONTEND=noninteractive apt-get install -y keepalived && break; sleep 5; done'",
        "echo '${var.sudo_password}' | sudo -S mkdir -p /etc/keepalived",
      ],
      # ヘルスチェックのスクリプトは、keepalived が設定を読む前に置く。
      length(var.extra_instances) > 0 ? ["echo '${var.sudo_password}' | sudo -S install -m 0755 /tmp/check-core-router.sh /etc/keepalived/check-core-router.sh"] : [],
      [
        "echo '${var.sudo_password}' | sudo -S cp /tmp/keepalived.conf /etc/keepalived/keepalived.conf",
        "echo '${var.sudo_password}' | sudo -S systemctl enable --now keepalived",
        # restart だと既存の VRRP インスタンス(ゲートウェイ VIP 10.0.0.254)が一瞬途切れるので、reload を優先する。
        "echo '${var.sudo_password}' | sudo -S systemctl reload-or-restart keepalived",
        "rm -f /tmp/keepalived.conf /tmp/check-core-router.sh",
      ]
    )
  }
}
