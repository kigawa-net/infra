#!/bin/bash
# files/maas-rack-shim.sh のテスト。偽の apt-get / dpkg-deb / dpkg-query / python3 を使い、実機にも、ネットワークにも触れない。
#   bash hardware/modules/maas-rack/test-maas-rack-shim.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SHIM="$here/files/maas-rack-shim.sh"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
ng() { fail=$((fail + 1)); echo "FAIL - $1"; [ -f "${sb:-/nonexistent}/out" ] && tail -6 "$sb/out" | sed 's/^/       | /'; }
chk() { if ( eval "$2" ); then ok "$1"; else ng "$1"; fi; }

REL=usr/lib/python3/dist-packages/maasservicelayer
VER='1:3.7.4-18072-g.5db61257d-0ubuntu1~24.04.1'

# 環境変数: NODEB=1(apt-get download が deb を作らない)、PYFAIL=1(python3 の import が、いつも失敗する)
mksb() {
  sb=$(mktemp -d)
  mkdir -p "$sb/bin" "$sb/shim" "$sb/real" "$sb/work" "$sb/src/$REL/logging" "$sb/src/$REL/utils"
  : > "$sb/calls"
  echo "# init" > "$sb/src/$REL/__init__.py"
  : > "$sb/src/$REL/logging/__init__.py"
  echo "class CustomJsonFormatter: pass" > "$sb/src/$REL/logging/configure.py"
  : > "$sb/src/$REL/utils/__init__.py"
  echo "def utcnow(): pass" > "$sb/src/$REL/utils/date.py"
  (cd "$sb/src" && tar -c ./usr) > "$sb/region.tar"
  cat > "$sb/bin/dpkg-query" <<EOF
#!/bin/bash
printf '%s' "$VER"
EOF
  cat > "$sb/bin/apt-get" <<EOF
#!/bin/bash
echo "apt-get \$*" >> "$sb/calls"
if [ "\$1" = download ] && [ "${NODEB:-0}" != 1 ]; then : > "maas-region-api_\${2#*=}_all.deb"; fi
exit 0
EOF
  cat > "$sb/bin/dpkg-deb" <<EOF
#!/bin/bash
echo "dpkg-deb \$*" >> "$sb/calls"
cat "$sb/region.tar"
EOF
  cat > "$sb/bin/python3" <<EOF
#!/bin/bash
echo "python3 \$*" >> "$sb/calls"
[ "${PYFAIL:-0}" = 1 ] && exit 1
[ -f "$sb/shim/maasservicelayer/logging/configure.py" ] && exit 0
exit 1
EOF
  chmod +x "$sb"/bin/*
}

run_shim() { # 引数: 追加の環境変数(KEY=VAL ...)
  env EXTRA_PATH="$sb/bin" SHIM_DIR="$sb/shim" REAL_DIR="$sb/real" WORK_DIR="$sb/work" "$@" bash "$SHIM" > "$sb/out" 2>&1
}

# ---- 1. 必要なとき: 回避を入れる ----
mksb
run_shim; rc=$?
chk "入れる: 終了コード 0" '[ "$rc" = 0 ]'
chk "入れる: shim: installed を出す" 'grep -q "^shim: installed" "$sb/out"'
chk "入れる: 5 ファイルが置かれた" 'for f in __init__.py logging/__init__.py logging/configure.py utils/__init__.py utils/date.py; do [ -e "$sb/shim/maasservicelayer/$f" ] || exit 1; done'
chk "入れる: 目印のファイルがある" '[ -e "$sb/shim/maasservicelayer/.maas-rack-shim" ]'
chk "入れる: 依存の python3-pythonjsonlogger と python3-structlog を入れた" 'grep -q "^apt-get install -y python3-pythonjsonlogger python3-structlog" "$sb/calls"'
chk "入れる: 実際に入っている版の maas-region-api を取得した" 'grep -qF "apt-get download maas-region-api=$VER" "$sb/calls"'
chk "入れる: 一時ディレクトリを残さない" '[ -z "$(ls -A "$sb/work")" ]'
chk "入れる: 取り出したのは、maasservicelayer の 5 ファイルだけ(tar の対象を指定)" '[ "$(find "$sb/shim" -type f ! -name .maas-rack-shim | wc -l)" = 5 ]'

# ---- 2. 冪等: 2 回目は、何もしない ----
: > "$sb/calls"
run_shim; rc=$?
chk "冪等: 終了コード 0" '[ "$rc" = 0 ]'
chk "冪等: shim: present" 'grep -q "^shim: present" "$sb/out"'
chk "冪等: apt-get を呼ばない" '! grep -q "^apt-get" "$sb/calls"'
rm -rf "$sb"

# ---- 3. 本物が入っていて、回避の目印がある: 回避を外す ----
mksb
run_shim >/dev/null; rc=$?
mkdir -p "$sb/real/maasservicelayer/logging"; : > "$sb/real/maasservicelayer/logging/configure.py"
: > "$sb/calls"
run_shim; rc=$?
chk "本物が入った: 回避を外す" '[ "$rc" = 0 ] && grep -q "^shim: removed" "$sb/out" && [ ! -e "$sb/shim/maasservicelayer" ]'
chk "本物が入った: apt-get を呼ばない" '! grep -q "^apt-get" "$sb/calls"'
rm -rf "$sb"

# ---- 4. 本物が入っていて、回避の目印が無い: 何もしない(本物のパッケージのファイルは触らない) ----
mksb
mkdir -p "$sb/real/maasservicelayer/logging" "$sb/shim/maasservicelayer"; : > "$sb/real/maasservicelayer/logging/configure.py"; echo keep > "$sb/shim/maasservicelayer/other.py"
run_shim; rc=$?
chk "本物あり・目印なし: not needed" '[ "$rc" = 0 ] && grep -q "^shim: not needed" "$sb/out"'
chk "本物あり・目印なし: 既存のファイルを消さない" '[ -e "$sb/shim/maasservicelayer/other.py" ]'
rm -rf "$sb"

# ---- 5. deb を取得できない: 中止し、何も置かない ----
NODEB=1 mksb
run_shim NODEB=1; rc=$?
chk "取得失敗: 中止(終了コード 1)" '[ "$rc" = 1 ]'
chk "取得失敗: 何も置かない" '[ ! -e "$sb/shim/maasservicelayer" ]'
rm -rf "$sb"

# ---- 6. 置いても import できない: 中止 ----
PYFAIL=1 mksb
run_shim PYFAIL=1; rc=$?
chk "import 不可: 中止(終了コード 1)" '[ "$rc" = 1 ] && grep -q "import できない" "$sb/out"'
rm -rf "$sb"

# ---- 7. 静的な確認 ----
chk "shim.sh の構文" 'bash -n "$SHIM"'
chk "shim.sh は、リポジトリに maasservicelayer の中身を複製していない(deb から取り出す)" '! grep -q "CustomJsonFormatter" "$SHIM"'
chk "shim.sh は apt-get remove / purge / autoremove を使わない(コメント行は除く)" '! grep -v "^[[:space:]]*#" "$SHIM" | grep -E "apt-get (remove|purge|autoremove)"'

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
