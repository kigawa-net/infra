#!/bin/bash
# MAAS 用の Wake on LAN の webhook(files/maas-wol-webhook.py)を、Rack に systemd サービスとして入れる(kigawa-net/infra#316、#317)。
# MAAS には WoL の電源ドライバが無く、`webhook` ドライバで、この 127.0.0.1 のサービスを呼ぶ。
# 冪等。ほかのサービス(maas-rackd・maas-dhcpd など)には触れない。ファイルが変わったときだけ、このサービスを再起動する。
# SSH によるシャットダウン(/off。kigawa-net/infra#416)の設定は、任意。SHUTDOWN_TARGETS_SRC(表の JSON)、SHUTDOWN_KEY_SRC(秘密鍵)、
# SHUTDOWN_KNOWN_HOSTS_SRC(known_hosts)、SHUTDOWN_AUTH_TOKEN_SRC(/off の認証トークン。#417)の 4 つを、**そろえて**渡したときだけ、CONF_DIR(既定 /etc/maas-wol-webhook)に置く。
# 1 つも渡さなければ、CONF_DIR の設定ファイルを消す(無効にしても、古い鍵を残さない)。一部だけは中止する。
# 環境変数: BCAST(必須。マジックパケットの宛先。例 192.168.1.255)、PORT(既定 5290)、SRC(既定 /tmp/maas-wol-webhook.py)、
#           SBIN_DIR(既定 /usr/local/sbin)、UNIT_DIR(既定 /etc/systemd/system)、CONF_DIR(既定 /etc/maas-wol-webhook)、
#           SKIP_VERIFY(1 なら、起動後の応答の確認をしない。テスト用)
set -euo pipefail

export PATH="${EXTRA_PATH:+$EXTRA_PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"  # EXTRA_PATH は、テストで偽のコマンドを差し込むためだけに使う
: "${BCAST:?BCAST が未設定}"
PORT=${PORT:-5290}
SRC=${SRC:-/tmp/maas-wol-webhook.py}
SBIN_DIR=${SBIN_DIR:-/usr/local/sbin}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
SKIP_VERIFY=${SKIP_VERIFY:-0}
CONF_DIR=${CONF_DIR:-/etc/maas-wol-webhook}
SHUTDOWN_TARGETS_SRC=${SHUTDOWN_TARGETS_SRC:-}
SHUTDOWN_KEY_SRC=${SHUTDOWN_KEY_SRC:-}
SHUTDOWN_KNOWN_HOSTS_SRC=${SHUTDOWN_KNOWN_HOSTS_SRC:-}
SHUTDOWN_AUTH_TOKEN_SRC=${SHUTDOWN_AUTH_TOKEN_SRC:-}

printf '%s' "$BCAST" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || { echo "ABORT: BCAST は IPv4 アドレスにする($BCAST)" >&2; exit 1; }
printf '%s' "$PORT" | grep -Eq '^[0-9]{2,5}$' || { echo "ABORT: PORT が不正($PORT)" >&2; exit 1; }
[ -s "$SRC" ] || { echo "ABORT: webhook のスクリプトが無い($SRC)" >&2; exit 1; }

# SSH のシャットダウンの設定は、4 つそろうか、4 つとも空か(一部だけは、中止する。何も変えない)。
n_shutdown=0
for v in "$SHUTDOWN_TARGETS_SRC" "$SHUTDOWN_KEY_SRC" "$SHUTDOWN_KNOWN_HOSTS_SRC" "$SHUTDOWN_AUTH_TOKEN_SRC"; do
  [ -n "$v" ] && n_shutdown=$((n_shutdown + 1))
done
if [ "$n_shutdown" != 0 ] && [ "$n_shutdown" != 4 ]; then
  echo "ABORT: SHUTDOWN_TARGETS_SRC・SHUTDOWN_KEY_SRC・SHUTDOWN_KNOWN_HOSTS_SRC・SHUTDOWN_AUTH_TOKEN_SRC は、4 つそろえるか、4 つとも空にする(一部だけは不可)" >&2
  exit 1
fi
if [ "$n_shutdown" = 4 ]; then
  for f in "$SHUTDOWN_TARGETS_SRC" "$SHUTDOWN_KEY_SRC" "$SHUTDOWN_KNOWN_HOSTS_SRC" "$SHUTDOWN_AUTH_TOKEN_SRC"; do
    [ -s "$f" ] || { echo "ABORT: 空、または無いファイル($f)" >&2; exit 1; }
  done
  command -v ssh >/dev/null || { echo "ABORT: ssh が無い(openssh-client を入れる)" >&2; exit 1; }
  # 秘密鍵の形式の検査。パスフレーズ付きの鍵は、BatchMode では使えないので、ここで止める(</dev/null で、入力待ちにしない)
  ssh-keygen -y -f "$SHUTDOWN_KEY_SRC" </dev/null >/dev/null 2>&1 || { echo "ABORT: 秘密鍵の形式が不正(ssh-keygen -y -f が失敗。パスフレーズ無しの OpenSSH 形式にする)" >&2; exit 1; }
  # /off の認証トークン: 32 文字以上で、使ってよい文字だけ(改行や空白は、認証の比較と、設定ファイルの形を壊すので不可)
  tok=$(cat "$SHUTDOWN_AUTH_TOKEN_SRC")
  tok_re='^[A-Za-z0-9._~+/=-]{32,}$'
  [[ "$tok" =~ $tok_re ]] || { echo "ABORT: 認証トークンの形式が不正(32 文字以上の [A-Za-z0-9._~+/=-] のみ)" >&2; exit 1; }
  unset tok
fi

DST="$SBIN_DIR/maas-wol-webhook.py"
UNIT="$UNIT_DIR/maas-wol-webhook.service"
install -d -m 0755 "$SBIN_DIR" "$UNIT_DIR"

changed=0
if ! cmp -s "$SRC" "$DST" 2>/dev/null; then install -m 0755 "$SRC" "$DST"; changed=1; fi
rm -f "$SRC"

# シャットダウンの設定(秘密鍵を含む)。ディレクトリは 0700 root。鍵は 0600、表と known_hosts は 0644。
install -d -m 0700 "$CONF_DIR"
put_file() { # 引数: 元, 先, 権限。内容が変わったときだけ置く
  if ! cmp -s "$1" "$2" 2>/dev/null; then install -m "$3" "$1" "$2"; changed=1; fi
}
if [ "$n_shutdown" = 4 ]; then
  put_file "$SHUTDOWN_TARGETS_SRC" "$CONF_DIR/shutdown-targets.json" 0644
  put_file "$SHUTDOWN_KEY_SRC" "$CONF_DIR/shutdown.key" 0600
  put_file "$SHUTDOWN_KNOWN_HOSTS_SRC" "$CONF_DIR/known_hosts" 0644
  put_file "$SHUTDOWN_AUTH_TOKEN_SRC" "$CONF_DIR/auth-token" 0600
  # 置いたら、元のファイルを消す(秘密を、ステージの場所に残さない)
  rm -f "$SHUTDOWN_TARGETS_SRC" "$SHUTDOWN_KEY_SRC" "$SHUTDOWN_KNOWN_HOSTS_SRC" "$SHUTDOWN_AUTH_TOKEN_SRC"
else
  # 無効: 置いてあった設定を消す(古い鍵を残さない。/off は、表が無ければ unsupported になる)
  for f in shutdown-targets.json shutdown.key known_hosts auth-token; do
    if [ -e "$CONF_DIR/$f" ]; then rm -f "$CONF_DIR/$f"; changed=1; fi
  done
fi

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
Environment=SHUTDOWN_TARGETS=$CONF_DIR/shutdown-targets.json
Environment=SHUTDOWN_KEY=$CONF_DIR/shutdown.key
Environment=SHUTDOWN_KNOWN_HOSTS=$CONF_DIR/known_hosts
Environment=AUTH_TOKEN_FILE=$CONF_DIR/auth-token
ExecStart=/usr/bin/python3 $DST
Restart=on-failure
RestartSec=3
# 認証が無いので、ループバックだけで待ち受け(スクリプトも、それ以外の BIND を拒否する)。権限は、ping と、ブロードキャストに必要なものだけ。
# SSH(/off)のシャットダウン: ssh は、IPv4 の TCP だけを使う(RestrictAddressFamilies=AF_INET。AF_UNIX は、ローカルの通信のため)。
#   ssh は -F /dev/null と UserKnownHostsFile・-i を明示するので、~/.ssh を読まない(ProtectHome=true で、/root と /home は空に見える)。
#   鍵と known_hosts は、CONF_DIR(root 所有、読み取り専用)。ssh のクライアントは、特権の capability を使わない(CAP_NET_RAW だけで動く見込み。実機で未確認)。
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_RAW
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ReadOnlyPaths=/var/lib/maas $CONF_DIR
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
echo "maas-wol-webhook: $( [ "$changed" = 1 ] && echo 更新して起動 || echo 変更なし)(127.0.0.1:$PORT、BCAST=$BCAST、SSH のシャットダウン: $( [ "$n_shutdown" = 4 ] && echo 有効 || echo 無効))"
