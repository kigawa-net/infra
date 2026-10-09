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

  # kigawa-net/infra#221: zone ファイルを配るだけでは、動いている knot(静的 Pod)は古い zone のままだった
  # (2026-10-04、#211 / #220 の apply が成功しても、新しい名前が引けなかった。手動の `knotc zone-reload` で反映した)。
  # 配備した zone を、動いている knot に再読み込みさせる。
  # - knot のコンテナが無い(初回の構築、Pod の再作成中)ときは、何もしない(新しい Pod は、起動時に zone を読む)。
  # - 再読み込みに失敗しても、apply は失敗にしない(zone ファイルの配備は済んでいる。警告を出す)。
  # - knot.conf が変わった場合は、zone の再読み込みでは反映されない(静的 Pod の manifest の更新・再作成が要る)。
  zone_reload_script = <<-SCRIPT
    #!/bin/bash
    set -u
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    export CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock
    cid=$(crictl ps --name '^knot$' -q 2>/dev/null | head -1)
    if [ -z "$cid" ]; then
      echo "knot のコンテナが無いため、zone の再読み込みを省略する"
      exit 0
    fi
    for z in ${join(" ", keys(var.zones))}; do
      if crictl exec "$cid" knotc zone-reload "$z" >/dev/null 2>&1; then
        echo "zone-reload: $z OK"
      else
        echo "WARNING: zone-reload に失敗した: $z"
      fi
    done
    crictl exec "$cid" knotc zone-status 2>/dev/null || true
  SCRIPT
}

resource "null_resource" "knot" {
  triggers = {
    host      = var.host
    knot_conf = local.knot_conf
    # var.zones changes (e.g. editing hardware/zones/*.zone) previously went undetected:
    # the provisioners below that actually deploy zone files only run on resource
    # create/replace, and this trigger set had no reference to zone *content* at all.
    zones          = jsonencode(var.zones)
    reload_script  = sha256(local.zone_reload_script)
    script_version = "5"
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
    # デフォルトの5分だとk8s1(既知の低速ディスク問題)でapt-get等が
    # 間に合わずremote-execがタイムアウトする(失敗ログが毎回5m46-47秒
    # で揃っていたことから確認)ため延長する
    timeout = "20m"
  }

  # 同一ホスト上の他モジュール(control_plane/wireguard/keepalived等)のapt-getとの
  # 並列実行やOSのunattended-upgradesとの競合でdpkgロックが取れず失敗することが
  # ある。事前にロックが空くのを待つだけではチェック直後に別プロセスが取って
  # しまうTOCTOU競合があるため、失敗した場合はリトライする
  # (hardware/modules/wireguardと同じ対応)。
  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash -c 'wait_lock() { for i in $(seq 1 60); do fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1 || return 0; sleep 5; done; return 1; }; for a in $(seq 1 20); do wait_lock; apt-get update && apt-get install -y knot && break; sleep 5; done'",
      "echo '${var.sudo_password}' | sudo -S mkdir -p /var/lib/knot",
    ]
  }

  provisioner "file" {
    content     = local.knot_conf
    destination = "/tmp/knot.conf"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S cp /tmp/knot.conf /etc/knot/knot.conf",
    ]
  }

  # Deploy zone files with base64 encoding
  provisioner "remote-exec" {
    inline = concat(
      ["echo 'Deploying zone files...'"],
      [for zone_name, zone_content in var.zones :
        "echo '${var.sudo_password}' | sudo -S bash -c 'echo ${base64encode(zone_content)} | base64 -d > /var/lib/knot/${zone_name}.zone'"
      ]
    )
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S chown -R knot:knot /var/lib/knot",
      # kigawa-net/infra#192: 認証DNSは静的Pod manifest
      # (/etc/kubernetes/manifests/knot.yaml、cznic/knot:latestコンテナ)として
      # ポート127.0.0.1:5353で稼働する設計で、このモジュールはそのPodが読む
      # /etc/knot/knot.conf・/var/lib/knot/配下のzoneファイルを配備するのが
      # 本来の役目。以前はここで`systemctl enable knot` + `systemctl restart knot`
      # によりホストネイティブなknot.serviceも同時に有効化・起動しており、
      # hardware/modules/knot-resolverのインストールスクリプトがknot.serviceを
      # maskする想定(「authoritative DNS already runs as a container on
      # 127.0.0.1:5353」というコメント参照)と矛盾していた。このモジュールが
      # 再適用されるたびにmaskが解除されknot.serviceが再有効化され、静的Podと
      # 同じポートを取り合ってクラッシュループする障害が実際に発生した
      # (k8s2/k8s4で44〜47時間継続)。ホストネイティブ側は明示的に停止・
      # 無効化・maskし、静的Podのみがポートを保持するようにする。
      "echo '${var.sudo_password}' | sudo -S systemctl stop knot.service || true",
      "echo '${var.sudo_password}' | sudo -S systemctl disable knot.service || true",
      "echo '${var.sudo_password}' | sudo -S systemctl mask knot.service || true",
      "echo 'Knot config/zones deployed; host-native knot.service masked (static pod serves DNS)'",
    ]
  }

  provisioner "file" {
    content     = local.zone_reload_script
    destination = "/tmp/knot-zone-reload.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S bash /tmp/knot-zone-reload.sh",
      "rm -f /tmp/knot-zone-reload.sh",
    ]
  }

  provisioner "remote-exec" {
    inline = [
      "rm -f /tmp/knot.conf",
    ]
  }
}
