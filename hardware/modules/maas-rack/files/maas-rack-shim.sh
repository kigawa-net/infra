#!/bin/bash
# MAAS 3.7.x の Rack の不具合の回避(kigawa-net/infra#317)。
# 3.7.4 の maas-rackd は、起動時のログ設定(provisioningserver/logger/_logging.py の get_logging_config)で、書式 fips_json を必ず組み立て、
# そのために maasservicelayer.logging.configure を import する。maasservicelayer は maas-region-api にしか入っていないので、
# **Region を同居させない Rack では、rackd が `ValueError: Unable to configure formatter 'fips_json'` で、起動できない**(新規導入でも再現)。
# 回避: 実際に入っている版の maas-region-api の deb から、必要な 5 ファイルだけを取り出し、/usr/local の dist-packages に置く(dpkg の管理外。リポジトリには複製しない)。
#       あわせて、依存の python3-pythonjsonlogger と python3-structlog を入れる。
# 本物のパッケージが maasservicelayer を提供するようになったら(/usr/lib/python3/dist-packages に現れたら)、この回避のファイルを外す(古いファイルが本物を隠さないように)。
# 冪等。標準出力に、"shim: installed" / "shim: removed" / "shim: not needed" / "shim: present" のどれかを出す。
# 環境変数: MAAS_RACK_VERSION(省略時は dpkg-query で、maas-rack-controller の版を調べる)、SHIM_DIR・REAL_DIR・WORK_DIR(テスト用に差し替え可)
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="${EXTRA_PATH:+$EXTRA_PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"  # EXTRA_PATH は、テストで偽のコマンドを差し込むためだけに使う
SHIM_DIR=${SHIM_DIR:-/usr/local/lib/python3.12/dist-packages}
REAL_DIR=${REAL_DIR:-/usr/lib/python3/dist-packages}
MARKER="$SHIM_DIR/maasservicelayer/.maas-rack-shim"
REL=usr/lib/python3/dist-packages/maasservicelayer
FILES="__init__.py logging/__init__.py logging/configure.py utils/__init__.py utils/date.py"

# 本物が入っている(maas-region-api、または、修正された Rack)なら、回避のファイルは、要らない。外す。
if [ -f "$REAL_DIR/maasservicelayer/logging/configure.py" ]; then
    if [ -e "$MARKER" ]; then
        rm -rf "$SHIM_DIR/maasservicelayer"
        echo "shim: removed(本物の maasservicelayer が入っているため)"
    else
        echo "shim: not needed(本物の maasservicelayer が入っている)"
    fi
    exit 0
fi

# すでに、import できるなら、何もしない。
if python3 -c 'import maasservicelayer.logging.configure' >/dev/null 2>&1; then
    echo "shim: present"
    exit 0
fi

ver=${MAAS_RACK_VERSION:-$(dpkg-query -W -f='${Version}' maas-rack-controller 2>/dev/null || true)}
[ -n "$ver" ] || { echo "ABORT: maas-rack-controller の版が分からない" >&2; exit 1; }

apt-get install -y python3-pythonjsonlogger python3-structlog >/dev/null

work=$(mktemp -d "${WORK_DIR:-/tmp}/maas-rack-shim.XXXXXX")
trap 'rm -rf "$work"' EXIT
(cd "$work" && apt-get download "maas-region-api=$ver" >/dev/null)
deb=$(ls "$work"/maas-region-api_*.deb 2>/dev/null | head -n1 || true)
[ -n "$deb" ] || { echo "ABORT: maas-region-api=$ver の deb を取得できなかった" >&2; exit 1; }
paths=""
for f in $FILES; do paths="$paths ./$REL/$f"; done
# shellcheck disable=SC2086
dpkg-deb --fsys-tarfile "$deb" | tar -x -C "$work" $paths
for f in $FILES; do
    [ -e "$work/$REL/$f" ] || { echo "ABORT: deb に $f が無い" >&2; exit 1; }
    install -D -m 0644 "$work/$REL/$f" "$SHIM_DIR/maasservicelayer/$f"
done
echo "maas-region-api $ver から取り出した最小のファイル(kigawa-net/infra#317)。本物の maasservicelayer が入ったら外される" > "$MARKER"

if ! python3 -c 'import maasservicelayer.logging.configure' >/dev/null 2>&1; then
    echo "ABORT: 回避のファイルを置いたが、import できない" >&2
    exit 1
fi
echo "shim: installed(maas-region-api $ver から 5 ファイル)"
