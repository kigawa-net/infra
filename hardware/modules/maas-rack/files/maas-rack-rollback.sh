#!/bin/bash
# install_rack.sh の逆操作。導入前スナップショット($LOG_DIR/pre-installed.txt)との差分だけを purge する。
# autoremove は使わない(ホストの無関係なパッケージまで消えるため)。
# Usage: bash rollback_rack.sh   (root で実行)
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
LOG_DIR=/var/log/maas-rack-install
PRE="$LOG_DIR/pre-installed.txt"
[ -f "$PRE" ] || { echo "ABORT: 導入前スナップショットが無い($PRE)" >&2; exit 1; }

installed_now() {
    dpkg-query -W -f='${Package} ${Status}\n' | awk '$NF=="installed"{print $1}' | sort
}

# 1. MAAS の各サービスを止めて無効化する
systemctl disable --now maas-rackd.service maas-http.service maas-proxy.service \
    maas-syslog.service maas-agent.service maas-dhcpd.service maas-dhcpd6.service >/dev/null 2>&1 || true
systemctl unmask named.service bind9.service >/dev/null 2>&1 || true

# 2. 本体を purge
apt-get remove --purge -y maas-rack-controller

# 3. 導入で新規に入ったパッケージ(導入前には無かったもの)を purge する
installed_now > "$LOG_DIR/now-after-rollback-pre.txt"
comm -13 "$PRE" "$LOG_DIR/now-after-rollback-pre.txt" > "$LOG_DIR/added-packages.txt"
echo "purge (added by install): $(wc -l < "$LOG_DIR/added-packages.txt") packages"
if [ -s "$LOG_DIR/added-packages.txt" ]; then
    xargs -a "$LOG_DIR/added-packages.txt" apt-get purge -y
fi

# 3'. purge では残る実行時データ(登録情報・secret・ログ・ランタイム)を消す。
#     導入前に maas 系パッケージが無かった場合だけ(このスクリプトの前提)。
if ! grep -q 'maas' "$PRE"; then
    rm -rf /etc/maas /var/lib/maas /var/log/maas /run/maas
fi

# 4. 導入で削除された既存パッケージ(systemd-timesyncd)を戻す
installed_now > "$LOG_DIR/now.txt"
comm -23 "$PRE" "$LOG_DIR/now.txt" > "$LOG_DIR/restore-packages.txt"
echo "reinstall (removed by install): $(cat "$LOG_DIR/restore-packages.txt" | tr '\n' ' ')"
if [ -s "$LOG_DIR/restore-packages.txt" ]; then
    xargs -a "$LOG_DIR/restore-packages.txt" apt-get install -y --no-upgrade
fi
systemctl enable --now systemd-timesyncd.service >/dev/null 2>&1 || true

# 5. nginx の default サイトを導入前の状態に戻す
if grep -qx 'default' "$LOG_DIR/nginx-sites-enabled-before.txt"; then
    ln -sfn /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
fi
if [ "$(cat "$LOG_DIR/nginx-enabled-before.txt" 2>/dev/null)" = "enabled" ]; then
    systemctl enable nginx.service >/dev/null 2>&1 || true
fi
systemctl reload nginx >/dev/null 2>&1 || true

# 6. PPA を導入前の状態に戻す
if [ "$(cat "$LOG_DIR/pre-ppa.txt")" = "no" ]; then
    add-apt-repository -y --remove ppa:maas/3.6 || true
fi
apt-get update -qq || true

echo "rollback_rack.sh: done"
