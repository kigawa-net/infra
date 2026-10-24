#!/bin/bash
# MAAS の Rack コントローラーを、目標のバージョン(MAAS_VERSION。例: 3.7)に上げる(kigawa-net/infra#317)。
# Rack は Region より新しくできない。**Region(k8s の maas-region)を先に上げてから**、この script を実行する。
# 冪等: すでに目標のバージョンなら、更新はせず、サービスの確認だけ行う(前回の更新が、途中で失敗していたら、ここで気付く)。
#       入っていなければ、スキップ(新規導入は maas-rack-install.sh の役目)。下げる方向は、中止。
# 環境変数: MAAS_VERSION(必須。major.minor)、LOG_DIR・APT_SOURCES_DIR・MAAS_ETC_DIR・MAAS_VAR_DIR(テスト用に差し替え可)、
#           SERVICE_WAIT_SEC(更新後に、サービスが active になるのを待つ秒数。既定 90)
# DHCP(maas-dhcpd)は、rackd が管理する。この script は、有効・無効にしない。
# ただし、**更新の前に active だった maas-dhcpd が、更新の後に active でなければ、失敗とする**(DHCP の failover の相手は、この Rack が戻るまで 1 台で担う)。
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="${EXTRA_PATH:+$EXTRA_PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"  # EXTRA_PATH は、テストで偽のコマンドを差し込むためだけに使う
: "${MAAS_VERSION:?MAAS_VERSION が未設定}"
LOG_DIR=${LOG_DIR:-/var/log/maas-rack-install}
APT_SOURCES_DIR=${APT_SOURCES_DIR:-/etc/apt/sources.list.d}
MAAS_ETC_DIR=${MAAS_ETC_DIR:-/etc/maas}
MAAS_VAR_DIR=${MAAS_VAR_DIR:-/var/lib/maas}
SERVICE_WAIT_SEC=${SERVICE_WAIT_SEC:-90}
# 更新の計画で、アップグレード(Inst <pkg> [<旧版>])を許すパッケージ名。これ以外のアップグレードが計画に入ったら中止する
# (--only-upgrade は、依存パッケージの更新を止めない。ホストの無関係なサービスが、maintainer script で再起動されうる)。新規のインストール(旧版なし)は許す。
UPGRADE_ALLOW_REGEX=${UPGRADE_ALLOW_REGEX:-'^(maas|python3-maas)'}
mkdir -p "$LOG_DIR"

installed=$(dpkg-query -W -f='${Version}' maas-rack-controller 2>/dev/null || true)
if [ -z "$installed" ]; then
    echo "upgrade: maas-rack-controller が入っていない。スキップ(新規導入は maas-rack-install.sh)"
    exit 0
fi
status=$(dpkg-query -W -f='${Status}' maas-rack-controller 2>/dev/null || true)
if [ "$status" != "install ok installed" ]; then
    echo "ABORT: maas-rack-controller が、中途半端な状態($status)。dpkg --configure -a などで直してから、再実行する" >&2
    exit 1
fi
# 1:3.6.6-17672-g.08d455f29-0ubuntu1~24.04.1 -> 3.6
cur=$(printf '%s' "$installed" | sed -E 's/^[0-9]+://; s/^([0-9]+\.[0-9]+).*/\1/')
if [ "$(printf '%s\n%s\n' "$cur" "$MAAS_VERSION" | sort -V | head -n1)" != "$cur" ]; then
    echo "ABORT: 現在の $cur より古い $MAAS_VERSION への変更(ダウングレード)は、しない" >&2
    exit 1
fi

ts=$(date +%Y%m%d-%H%M%S)
BK="$LOG_DIR/upgrade-before-$ts"
dhcpd_before=$(systemctl is-active maas-dhcpd.service 2>/dev/null || true)

if [ "$cur" = "$MAAS_VERSION" ]; then
    verify_only=1
    echo "upgrade: すでに $MAAS_VERSION($installed)。更新はせず、サービスの確認だけ行う"
else
    verify_only=0
    echo "upgrade: $cur($installed) -> $MAAS_VERSION"

    # 0. 更新前のバックアップ(設定と、パッケージの一覧。secret を含むので、root だけが読める)
    install -d -m 0700 "$BK"
    [ -d "$MAAS_ETC_DIR" ] && cp -a "$MAAS_ETC_DIR" "$BK/etc-maas"
    [ -f "$MAAS_VAR_DIR/secret" ] && cp -a "$MAAS_VAR_DIR/secret" "$BK/var-lib-maas-secret"
    dpkg-query -W -f='${Package} ${Version}\n' 'maas*' 'python3-maas*' > "$BK/packages.txt" 2>/dev/null || true
    for u in maas-rackd maas-agent maas-dhcpd; do
        echo "$u $(systemctl is-active "$u.service" 2>/dev/null || true)" >> "$BK/services-before.txt"
    done

    # 1. PPA(冪等)
    if ! grep -rqs "maas/$MAAS_VERSION" "$APT_SOURCES_DIR"/ 2>/dev/null; then
        add-apt-repository -y "ppa:maas/$MAAS_VERSION"
    fi
    apt-get update -qq

    # 2. 更新の計画の確認。入っている maas 系のパッケージだけを上げる。削除、無関係なパッケージのアップグレードは、中止。
    pkgs=$(dpkg-query -W -f='${Package} ${Status}\n' 'maas*' 'python3-maas*' 2>/dev/null | awk '$NF=="installed"{print $1}' | sort -u | tr '\n' ' ')
    [ -n "$pkgs" ] || { echo "ABORT: 更新対象の maas 系のパッケージが見つからない" >&2; exit 1; }
    PLAN="$LOG_DIR/upgrade-plan-$ts.txt"
    # shellcheck disable=SC2086
    apt-get -s install --only-upgrade $pkgs > "$PLAN"
    if grep -q '^Remv' "$PLAN"; then
        echo "ABORT: 更新の計画に、パッケージの削除が含まれる" >&2
        grep '^Remv' "$PLAN" >&2
        exit 1
    fi
    unexpected=$(grep -E '^Inst [^ ]+ \[' "$PLAN" | awk '{print $2}' | grep -vE "$UPGRADE_ALLOW_REGEX" || true)
    if [ -n "$unexpected" ]; then
        echo "ABORT: 更新の計画に、maas 系ではないパッケージのアップグレードが含まれる(ホストの他のサービスに影響しうる)" >&2
        printf '%s\n' "$unexpected" >&2
        exit 1
    fi
    if ! grep -qE "^Inst maas-rack-controller \[[^]]*\] \((1:)?${MAAS_VERSION}\." "$PLAN"; then
        echo "ABORT: maas-rack-controller の ${MAAS_VERSION} 系が、計画に無い(PPA が、その版を出していない)" >&2
        grep -E '^Inst maas-rack-controller' "$PLAN" >&2 || true
        exit 1
    fi
    echo "plan: install/upgrade=$(grep -c '^Inst' "$PLAN") remove=0"

    # 3. 更新。設定ファイルは、現状を維持する(確認の対話を出さない)。
    # shellcheck disable=SC2086
    apt-get install -y --only-upgrade -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef $pkgs > "$LOG_DIR/upgrade-install-$ts.log" 2>&1
    systemctl daemon-reload

    # 4. 再起動(register は不要。rackd.conf と secret は、そのまま残る)
    systemctl restart maas-rackd.service
    systemctl restart maas-agent.service || true
fi

# 5. サービスの確認。確認だけのときは、active でなければ、1 回だけ再起動を試す。
wait_active() { # $1 = unit
    local u=$1 _
    for _ in $(seq 1 "$SERVICE_WAIT_SEC"); do
        if [ "$(systemctl is-active "$u.service" 2>/dev/null || true)" = active ]; then return 0; fi
        sleep 1
    done
    return 1
}
fail=0
for u in maas-rackd maas-agent; do
    if [ "$verify_only" = 1 ] && [ "$(systemctl is-active "$u.service" 2>/dev/null || true)" != active ]; then
        echo "service: $u が active でない。再起動を試す"
        systemctl restart "$u.service" || true
    fi
    if wait_active "$u"; then echo "service: $u active"; else echo "service: $u が active にならない" >&2; fail=1; fi
done
# 更新の前に active だった DHCP は、更新の後も active であること(rackd が、設定を再適用して起動する)
if [ "$dhcpd_before" = active ]; then
    if wait_active maas-dhcpd; then echo "service: maas-dhcpd active(DHCP は、更新の前も active だった)"; else
        echo "service: maas-dhcpd が active に戻らない(更新の前は active だった)。DHCP が止まっている" >&2
        fail=1
    fi
else
    echo "service: maas-dhcpd は、更新の前から active ではない($dhcpd_before)。確認の対象外"
fi
if [ "$verify_only" = 0 ]; then
    install -d -m 0700 "$BK"
    for u in maas-rackd maas-agent maas-dhcpd; do
        echo "$u $(systemctl is-active "$u.service" 2>/dev/null || true)" >> "$BK/services-after.txt"
    done
    echo "version: $installed -> $(dpkg-query -W -f='${Version}' maas-rack-controller 2>/dev/null || true)"
fi
if [ "$fail" != 0 ]; then
    echo "maas-rack-upgrade.sh: サービスの確認に失敗。バックアップ: $BK(古い PPA は外さない。設定の戻し方は、docs/maas-design.md を参照)" >&2
    exit 1
fi

# 6. 古い PPA を外す(確認が成功した後だけ。新しい PPA の行は、残す)
removed_ppa=0
for f in $(grep -rls 'maas/[0-9]' "$APT_SOURCES_DIR"/ 2>/dev/null || true); do
    if ! grep -qs "maas/$MAAS_VERSION" "$f"; then
        rm -f "$f"
        removed_ppa=1
        echo "ppa: 古い $f を外した"
    fi
done
[ "$removed_ppa" = 0 ] || apt-get update -qq || true
echo "maas-rack-upgrade.sh: done"
