#!/bin/bash
# MAAS 3.6 の Rack コントローラーを、Ubuntu 24.04 のホストに deb で直接入れる(kigawa-net/infra#207、docs/maas-design.md)。
# 使い捨ての systemd 付き Ubuntu 24.04 コンテナで検証した手順に、空きメモリの事前チェックと、Region への登録を足したもの。
# 冪等: 2 回目以降は、インストール済みの状態に対して、同じ後処理だけを行う。
# 環境変数: MAAS_URL(必須。Region の URL)、MIN_AVAILABLE_MB(既定 2000)、SECRET_FILE(登録に使う secret のファイル。無ければ登録しない)
# DHCP(maas-dhcpd / maas-dhcpd6)は、この段階では起動も enable もしない(DHCP の切り替えは、後の別の段階)。
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="${EXTRA_PATH:+$EXTRA_PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"  # EXTRA_PATH は、テストで偽のコマンドを差し込むためだけに使う
LOG_DIR=${LOG_DIR:-/var/log/maas-rack-install}
POLICY=${POLICY:-/usr/sbin/policy-rc.d}
APT_SOURCES_DIR=${APT_SOURCES_DIR:-/etc/apt/sources.list.d}
NGINX_SITES_DIR=${NGINX_SITES_DIR:-/etc/nginx/sites-enabled}
MAAS_ETC_DIR=${MAAS_ETC_DIR:-/etc/maas}
MAAS_VAR_DIR=${MAAS_VAR_DIR:-/var/lib/maas}
CHRONY_DIR=${CHRONY_DIR:-/etc/chrony}
MIN_AVAILABLE_MB=${MIN_AVAILABLE_MB:-2000}
: "${MAAS_URL:?MAAS_URL が未設定}"
mkdir -p "$LOG_DIR"

# 0. 事前チェック: メモリの空き(導入で、squid・nginx・chrony・python などが増える。control-plane を逼迫させない)
avail_kb=$(awk '/^MemAvailable:/{print $2}' "${MEMINFO:-/proc/meminfo}")
if [ "$((avail_kb / 1024))" -lt "$MIN_AVAILABLE_MB" ]; then
    echo "ABORT: メモリの空きが少ない(${avail_kb} kB < ${MIN_AVAILABLE_MB} MB)。導入しない" >&2
    exit 1
fi

# ロールバック用の導入前スナップショット(初回のみ保存。2 回目以降は上書きしない)
if [ ! -e "$LOG_DIR/pre-installed.txt" ]; then
    dpkg-query -W -f='${Package} ${Status}\n' | awk '$NF=="installed"{print $1}' | sort > "$LOG_DIR/pre-installed.txt"
    ls "$NGINX_SITES_DIR"/ > "$LOG_DIR/nginx-sites-enabled-before.txt" 2>/dev/null || : > "$LOG_DIR/nginx-sites-enabled-before.txt"
    systemctl is-enabled nginx.service > "$LOG_DIR/nginx-enabled-before.txt" 2>/dev/null || true
    if grep -rqs 'maas/3.6' "$APT_SOURCES_DIR"/ 2>/dev/null; then echo yes; else echo no; fi > "$LOG_DIR/pre-ppa.txt"
fi

# パッケージ導入中に、サービスが自動起動しないように止める。失敗時も必ず外す。
# (導入の途中で失敗すると、パッケージは中途半端な状態で残る。maas-rack-rollback.sh で戻す。自動では戻さない)
cleanup() { rm -f "$POLICY"; }
trap cleanup EXIT
printf '#!/bin/sh\n# maas-rack install: do not start services during package install\nexit 101\n' > "$POLICY"
chmod 0755 "$POLICY"

# 1. PPA(冪等)
if ! grep -rqs 'maas/3.6' "$APT_SOURCES_DIR"/ 2>/dev/null; then
    add-apt-repository -y ppa:maas/3.6
fi
apt-get update -qq

# 2. 導入計画の確認: 既存パッケージのアップグレード(Inst <pkg> [<旧版>])が無いこと
apt-get -s install --no-upgrade maas-rack-controller > "$LOG_DIR/plan.txt"
if grep -qE '^Inst [^ ]+ \[' "$LOG_DIR/plan.txt"; then
    echo "ABORT: 既存パッケージのアップグレードが計画に含まれる" >&2
    grep -E '^Inst [^ ]+ \[' "$LOG_DIR/plan.txt" >&2
    exit 1
fi
echo "plan: remove=$(grep -c '^Remv' "$LOG_DIR/plan.txt") install=$(grep -c '^Inst' "$LOG_DIR/plan.txt")"
grep '^Remv' "$LOG_DIR/plan.txt" || true

# 3. 本体のインストール(既存パッケージは上げない)
apt-get install -y --no-upgrade maas-rack-controller > "$LOG_DIR/install.log" 2>&1

# 4. policy-rc.d を外す(この後の systemctl 操作は通常どおり動く)
rm -f "$POLICY"

# 4'. systemd-timesyncd は削除されるが、prerm の停止は policy-rc.d に阻まれて、旧プロセスが残る。
#     ユニットは not-found になっているので、明示的に止める(chrony と時刻制御を取り合わないため)。
systemctl stop systemd-timesyncd.service >/dev/null 2>&1 || true
systemctl daemon-reload

# 4''. **時刻同期を最優先で用意する**(control-plane。etcd は時刻のずれに弱い)。
#      timesyncd は削除済みなので、この時点で、時刻同期のサービスが無い。登録など、後続の失敗に左右されないよう、先に、chrony を起動する。
#      MAAS の rackd は、登録の際に chrony.conf を書き換え、上流の server / pool を消し、/etc/chrony/maas.conf(local stratum 9 orphan と allow だけ)を include する
#      (Region の NTP の設定が空のため)。MAAS が書き換えない sources.d に、Ubuntu の pool(導入前の chrony.conf と同じ)を置く。
install -d -m 0755 "$CHRONY_DIR/sources.d"
cat > "$CHRONY_DIR/sources.d/ubuntu-pool.sources" <<'EOF'
# Ubuntu の既定の NTP(Rack の導入前の chrony.conf と同じ)。MAAS の rackd は chrony.conf と maas.conf を書き換え、
# 上流の server / pool を消すので、MAAS が触らない sources.d に置く(kigawa-net/infra#207)。
pool ntp.ubuntu.com        iburst maxsources 4
pool 0.ubuntu.pool.ntp.org iburst maxsources 1
pool 1.ubuntu.pool.ntp.org iburst maxsources 1
pool 2.ubuntu.pool.ntp.org iburst maxsources 2
EOF
chmod 0644 "$CHRONY_DIR/sources.d/ubuntu-pool.sources"
systemctl enable --now chrony.service
chronyc reload sources >/dev/null 2>&1 || true

# 5. 後処理
# bind9(named)は Rack では使わない。:53 は kresd が持つので mask する。
systemctl mask named.service bind9.service >/dev/null 2>&1 || true

# 標準の nginx default サイトを外す(:80 を空ける)。Rack の HTTP(maas-http)は /var/lib/maas/http/nginx.conf を -c で読む別の設定。
rm -f "$NGINX_SITES_DIR/default"
systemctl reload nginx 2>/dev/null || true

# avahi(mDNS 5353)は Rack に不要。無効化する(パッケージは残す)。
systemctl disable --now avahi-daemon.service avahi-daemon.socket >/dev/null 2>&1 || true

# DHCP は、パッケージの preset で enable になるので、明示的に無効化する。標準の isc-dhcp-server も同様。
systemctl disable --now maas-dhcpd.service maas-dhcpd6.service >/dev/null 2>&1 || true
systemctl disable --now isc-dhcp-server.service isc-dhcp-server6.service >/dev/null 2>&1 || true

# 6. Region への登録。secret は stdin で渡す(argv に出さない)。
#    「登録済み」は、rackd.conf に同じ URL があり、**かつ、共有 secret のファイルがある**ときだけ(URL だけだと、登録が途中で失敗した状態を、見逃す)。
#    登録の失敗では、後続(サービスの起動)を止めない。最後に、失敗として、終了コードに反映する。
register_rc=0
if [ -n "${SECRET_FILE:-}" ] && [ -s "$SECRET_FILE" ]; then
    if grep -qsF "$MAAS_URL" "$MAAS_ETC_DIR/rackd.conf" 2>/dev/null && [ -s "$MAAS_VAR_DIR/secret" ]; then
        echo "register: 登録済み($MAAS_URL、secret あり)。スキップ"
    else
        if maas-rack register --url "$MAAS_URL" < "$SECRET_FILE"; then
            echo "register: done"
        else
            register_rc=$?
            echo "register: 失敗(終了コード $register_rc)。後続のサービスの起動は続ける" >&2
        fi
    fi
    shred -u "$SECRET_FILE" 2>/dev/null || rm -f "$SECRET_FILE"
else
    echo "register: SECRET_FILE が無い。登録しない"
fi

# 7. Rack に必要なサービスだけ enable / start する。
#    maas-http / maas-proxy / maas-syslog / maas-agent は ConditionPathExists により、Region への登録までは起動しない。
#    **maas-rack register は maas-rackd を停止させる**ので、登録の後に、必ず、起動する。
systemctl enable maas-rackd.service maas-http.service maas-proxy.service maas-syslog.service maas-agent.service
systemctl start maas-rackd.service || true
systemctl start maas-http.service maas-proxy.service maas-syslog.service maas-agent.service || true

echo "time: chrony=$(systemctl is-active chrony.service 2>/dev/null || true) sources=$(chronyc -n sources 2>/dev/null | grep -c '^\^' || true)"
if [ "$register_rc" != 0 ]; then
    echo "maas-rack-install.sh: 登録に失敗(他の手順は完了)" >&2
    exit "$register_rc"
fi
echo "maas-rack-install.sh: done"
