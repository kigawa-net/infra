#!/bin/bash
# MAAS 用の Wake on LAN の webhook(files/maas-wol-webhook.py)を、Rack に systemd サービスとして入れる(kigawa-net/infra#316、#317)。
# MAAS には WoL の電源ドライバが無く、`webhook` ドライバで、この 127.0.0.1 のサービスを呼ぶ。
# 冪等。ほかのサービス(maas-rackd・maas-dhcpd など)には触れない。ファイルが変わったときだけ、このサービスを再起動する。
# 環境変数: BCAST(必須。マジックパケットの宛先。例 192.168.1.255)、PORT(既定 5290)、SRC(既定 /tmp/maas-wol-webhook.py)、
#           SBIN_DIR(既定 /usr/local/sbin)、UNIT_DIR(既定 /etc/systemd/system)、SKIP_VERIFY(1 なら、起動後の応答の確認をしない。テスト用)
set -euo pipefail

export PATH="${EXTRA_PATH:+$EXTRA_PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"  # EXTRA_PATH は、テストで偽のコマンドを差し込むためだけに使う
: "${BCAST:?BCAST が未設定}"
PORT=${PORT:-5290}
SRC=${SRC:-/tmp/maas-wol-webhook.py}
SBIN_DIR=${SBIN_DIR:-/usr/local/sbin}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
SKIP_VERIFY=${SKIP_VERIFY:-0}

printf '%s' "$BCAST" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || { echo "ABORT: BCAST は IPv4 アドレスにする($BCAST)" >&2; exit 1; }
printf '%s' "$PORT" | grep -Eq '^[0-9]{2,5}$' || { echo "ABORT: PORT が不正($PORT)" >&2; exit 1; }
[ -s "$SRC" ] || { echo "ABORT: webhook のスクリプトが無い($SRC)" >&2; exit 1; }

DST="$SBIN_DIR/maas-wol-webhook.py"
UNIT="$UNIT_DIR/maas-wol-webhook.service"
install -d -m 0755 "$SBIN_DIR" "$UNIT_DIR"

changed=0
if ! cmp -s "$SRC" "$DST" 2>/dev/null; then install -m 0755 "$SRC" "$DST"; changed=1; fi
rm -f "$SRC"

NEW_UNIT=$(cat <<EOF
[Unit]
Description=MAAS 用の Wake on LAN の webhook(127.0.0.1 だけ。kigawa-net/infra#316)
After=network-online.target
Wants=network-online.target

[Service]
Environment=BIND=127.0.0.1
Environment=PORT=$PORT
Environment=BCAST=$BCAST
Environment=LEASES=/var/lib/maas/dhcp/dhcpd.leases
ExecStart=/usr/bin/python3 $DST
Restart=on-failure
RestartSec=3
# 認証が無いので、ループバックだけで待ち受け(スクリプトも、それ以外の BIND を拒否する)。権限は、ping と、ブロードキャストに必要なものだけ。
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_RAW
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ReadOnlyPaths=/var/lib/maas
RestrictAddressFamilies=AF_INET AF_UNIX
ProtectKernelTunables=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF
)
if [ ! -f "$UNIT" ] || [ "$(cat "$UNIT")" != "$NEW_UNIT" ]; then
    printf '%s\n' "$NEW_UNIT" > "$UNIT"
    chmod 0644 "$UNIT"
    changed=1
fi

if [ "$changed" = 1 ]; then
    systemctl daemon-reload
    systemctl enable maas-wol-webhook.service
    systemctl restart maas-wol-webhook.service
else
    systemctl enable maas-wol-webhook.service
    systemctl is-active --quiet maas-wol-webhook.service || systemctl restart maas-wol-webhook.service
fi

if [ "$SKIP_VERIFY" != 1 ]; then
    ok=0
    for _ in $(seq 1 "${VERIFY_TRIES:-15}"); do
        if python3 -c "
import json, sys, urllib.request
r = urllib.request.urlopen('http://127.0.0.1:$PORT/status?mac=00:00:00:00:00:00', timeout=3)
d = json.load(r)
sys.exit(0 if d.get('status') in ('running', 'stopped') else 1)
" 2>/dev/null; then ok=1; break; fi
        sleep 1
    done
    if [ "$ok" != 1 ]; then
        echo "ABORT: maas-wol-webhook が応答しない(journalctl -u maas-wol-webhook を確認)" >&2
        exit 1
    fi
fi
echo "maas-wol-webhook: $( [ "$changed" = 1 ] && echo 更新して起動 || echo 変更なし)(127.0.0.1:$PORT、BCAST=$BCAST)"
