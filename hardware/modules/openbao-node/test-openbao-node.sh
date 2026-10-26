#!/bin/bash
# modules/openbao-node のオフラインテスト。実機にも Bitwarden にも、ネットワークにも触れない。
#   bash hardware/modules/openbao-node/test-openbao-node.sh
#
# 1. files/openbao.hcl.tpl の描画(templatefile を、出力だけの一時的な root で評価する。provider は使わない)
# 2. files/openbao-node-setup.sh の挙動(OPENBAO_ROOT を一時ディレクトリにし、偽の curl / systemctl / useradd を使う)
# 失敗の調査用に TEST_KEEP=1 を付けると、作業ディレクトリ(各 run の出力を含む)を残す。
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tpl="$here/files/openbao.hcl.tpl"
setup="$here/files/openbao-node-setup.sh"
work=$(mktemp -d)
trap '[ -n "${TEST_KEEP:-}" ] || rm -rf "$work"' EXIT
pass=0
fails=0
last_out=""

ok() { pass=$((pass + 1)); echo "ok   - $1"; }
check() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    fails=$((fails + 1))
    echo "FAIL - $1 (expected=$2 actual=$3)"
    [ -n "$last_out" ] && [ -f "$last_out" ] && sed 's/^/       | /' "$last_out" | tail -8
  fi
}

# ---------------------------------------------------------------
# 1. config の描画
# ---------------------------------------------------------------
render_dir="$work/render"
mkdir -p "$render_dir"
cat > "$render_dir/main.tf" <<EOF
output "rendered" {
  value = templatefile("$tpl", {
    node_id    = "bao-01"
    wg_address = "192.0.2.1"
    # モジュールは、自分自身を除いた一覧を渡す(modules/openbao-node/main.tf の retry_peers)
    peers = [
      { node_id = "bao-02", address = "192.0.2.2" },
      { node_id = "bao-03", address = "192.0.2.3" },
    ]
  })
}
EOF
conf="$work/bao.hcl"
if terraform -chdir="$render_dir" init -input=false -no-color >"$work/init.log" 2>&1 &&
   terraform -chdir="$render_dir" apply -auto-approve -input=false -no-color >"$work/apply.log" 2>&1 &&
   terraform -chdir="$render_dir" output -raw rendered > "$conf"; then
  ok "テンプレートを描画できる"
else
  fails=$((fails + 1))
  echo "FAIL - テンプレートの描画に失敗"
  tail -8 "$work/apply.log"
  : > "$conf"
fi

check "ui は無効" 1 "$(grep -c '^ui *= *false$' "$conf")"
check "listener が 2 つ(WireGuard IP と loopback)" 2 "$(grep -c '^listener "tcp"' "$conf")"
check "WireGuard IP の 8200 / 8201 で待ち受ける" 1 "$(grep -c 'address *= *"192.0.2.1:8200"' "$conf")"
check "cluster_address も WireGuard IP" 1 "$(grep -c 'cluster_address *= *"192.0.2.1:8201"' "$conf")"
check "loopback の listener がある" 1 "$(grep -c 'address *= *"127.0.0.1:8200"' "$conf")"
check "tls_min_version は全 listener で tls13" 2 "$(grep -c 'tls_min_version *= *"tls13"' "$conf")"
check "公開 IF / 全アドレスに bind しない" 0 "$(grep -c '0\.0\.0\.0\|address *= *":' "$conf")"
check "api_addr は WireGuard の https" 1 "$(grep -c '^api_addr *= *"https://192.0.2.1:8200"$' "$conf")"
check "cluster_addr は WireGuard の 8201" 1 "$(grep -c '^cluster_addr *= *"https://192.0.2.1:8201"$' "$conf")"
check "node_id が設定されている" 1 "$(grep -c 'node_id *= *"bao-01"' "$conf")"
check "retry_join は他の 2 ノードだけ" 2 "$(grep -c 'leader_api_addr' "$conf")"
check "retry_join に自分の宛先が無い" 0 "$(grep -c 'leader_api_addr *= *"https://192.0.2.1:8200"' "$conf")"
check "retry_join の宛先(bao-02, bao-03)" 2 "$(grep -c 'https://192.0.2.[23]:8200' "$conf")"
check "telemetry は認証必須" 1 "$(grep -c 'unauthenticated_metrics_access *= *false' "$conf")"
check "データ dir は /var/lib/openbao" 1 "$(grep -c 'path *= *"/var/lib/openbao"' "$conf")"
check "秘密鍵・token を設定に含まない" 0 "$(grep -ci 'PRIVATE\|root_token\|unseal' "$conf")"

# ---------------------------------------------------------------
# 2. setup script(偽の環境で実行)
# ---------------------------------------------------------------
# 偽の .deb: usr/bin/bao(version を返す。operator が呼ばれたら失敗させる)
mkdir -p "$work/pkg/DEBIAN" "$work/pkg/usr/bin"
cat > "$work/pkg/DEBIAN/control" <<'EOF'
Package: openbao
Version: 2.1.0
Architecture: amd64
Maintainer: test <test@example.invalid>
Description: fake openbao for tests
EOF
cat > "$work/pkg/usr/bin/bao" <<'EOF'
#!/bin/bash
echo "bao $*" >> "${FAKE_LOG:-/dev/null}"
case "$1" in
  version) echo "OpenBao v2.1.0 (test)" ;;
  operator) echo "operator init must not be run" >&2; exit 99 ;;
esac
EOF
chmod +x "$work/pkg/usr/bin/bao"
dpkg-deb --root-owner-group --build "$work/pkg" "$work/bao.deb" >/dev/null 2>&1 || { echo "dpkg-deb が失敗"; exit 1; }
deb_sha=$(sha256sum "$work/bao.deb" | awk '{print $1}')

mkdir -p "$work/fakebin"
# 偽の curl: -o の先へ固定の .deb をコピーする(FAKE_CURL_FAIL で失敗させる)
cat > "$work/fakebin/curl" <<'EOF'
#!/bin/bash
[ -n "${FAKE_CURL_FAIL:-}" ] && exit 22
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
cp "$FAKE_DEB" "$out"
EOF
# 偽の systemctl: 呼び出しを記録。起動状態は $FAKE_STATE/active で表す。FAKE_START_FAIL で start を失敗させる
cat > "$work/fakebin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$FAKE_LOG"
case "$1" in
  is-active) [ -f "$FAKE_STATE/active" ] && exit 0; exit 3 ;;
  start) [ -n "${FAKE_START_FAIL:-}" ] && exit 1; touch "$FAKE_STATE/active"; exit 0 ;;
  stop) rm -f "$FAKE_STATE/active"; exit 0 ;;
esac
exit 0
EOF
# 偽の useradd: 呼び出しだけ記録
cat > "$work/fakebin/useradd" <<'EOF'
#!/bin/bash
echo "useradd $*" >> "$FAKE_LOG"
EOF
chmod +x "$work/fakebin"/*

# new_sandbox <name>: sandbox を作り、stage(設定・unit・証明書)を置く
write_stage() {
  mkdir -p "$sb/stage"
  printf 'listener "tcp" {}\n' > "$sb/stage/openbao.hcl"
  printf '[Unit]\nDescription=test\n' > "$sb/stage/openbao.service"
  printf '%s\n' "${CERT:-CERT-1}" > "$sb/stage/tls.crt"
  printf '%s\n' "${KEY:-KEY-1}" > "$sb/stage/tls.key"
  printf 'CA-1\n' > "$sb/stage/ca.crt"
}
new_sandbox() {
  sb="$work/sb-$1"
  mkdir -p "$sb/root" "$sb/state"
  FAKE_LOG="$sb/calls"
  : > "$FAKE_LOG"
  write_stage
}

# run_setup: 1 回分の実行。出力は run<番号>.out に残す。呼び出し記録は、実行ごとに空にする
run_n=0
run_setup() {
  run_n=$((run_n + 1))
  last_out="$sb/run$run_n.out"
  : > "$FAKE_LOG"
  env -i PATH="$work/fakebin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    OPENBAO_ROOT="$sb/root" OPENBAO_VERSION=2.1.0 DEB_URL="https://example.invalid/bao.deb" \
    DEB_SHA256="${DEB_SHA256_OVERRIDE:-$deb_sha}" STAGE_DIR="$sb/stage" \
    WIPE_DATA_ON_FAILURE="${WIPE:-0}" FAKE_DEB="$work/bao.deb" FAKE_LOG="$FAKE_LOG" FAKE_STATE="$sb/state" \
    FAKE_CURL_FAIL="${CURL_FAIL:-}" FAKE_START_FAIL="${START_FAIL:-}" \
    bash "$setup" >"$last_out" 2>&1
  rc=$?
  cp "$FAKE_LOG" "$sb/run$run_n.calls"
}

exists() { if [ -e "$1" ]; then echo 1; else echo 0; fi; }

# (a) 初回構築: 成功し、鍵は 0600、operator init は呼ばれない
new_sandbox first
run_setup
check "初回構築が成功する" 0 "$rc"
check "bao バイナリが配置される" 1 "$(exists "$sb/root/usr/local/bin/bao")"
check "秘密鍵は 0600" 600 "$(stat -c %a "$sb/root/etc/openbao/tls/tls.key" 2>/dev/null)"
check "証明書は 0600" 600 "$(stat -c %a "$sb/root/etc/openbao/tls/tls.crt" 2>/dev/null)"
check "設定は配置される" 1 "$(exists "$sb/root/etc/openbao/openbao.hcl")"
check "unit は配置される" 1 "$(exists "$sb/root/etc/systemd/system/openbao.service")"
check "/var/lib/openbao が作られる" 1 "$(exists "$sb/root/var/lib/openbao")"
check "start が呼ばれる" 1 "$(grep -c '^systemctl start openbao' "$sb/run$run_n.calls")"
check "operator init は呼ばれない" 0 "$(grep -c '^bao operator' "$sb/run$run_n.calls")"
check "ステージの秘密鍵は消される" 0 "$(exists "$sb/stage")"

# (b) 再実行(変更なし): 再起動も再読込もしない
write_stage
run_setup
check "変更なしの再実行は成功する" 0 "$rc"
check "変更なしなら restart しない" 0 "$(grep -c 'systemctl restart' "$sb/run$run_n.calls")"
check "変更なしなら reload もしない" 0 "$(grep -c 'systemctl reload' "$sb/run$run_n.calls")"

# (c) 証明書だけ変わった: SIGHUP(reload)のみ。restart はしない
CERT=CERT-2 KEY=KEY-2 write_stage
run_setup
check "証明書の変更は成功する" 0 "$rc"
check "証明書の変更は reload(SIGHUP)" 1 "$(grep -c '^systemctl reload openbao' "$sb/run$run_n.calls")"
check "証明書の変更では restart しない" 0 "$(grep -c 'systemctl restart' "$sb/run$run_n.calls")"
check "配置された鍵が新しい内容" "KEY-2" "$(cat "$sb/root/etc/openbao/tls/tls.key")"

# (d) SHA256 が一致しない: 何も配置せず失敗する
new_sandbox badsha
DEB_SHA256_OVERRIDE=$(printf '%064d' 0) run_setup
check "SHA256 不一致は失敗する" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "SHA256 不一致では bao を配置しない" 0 "$(exists "$sb/root/usr/local/bin/bao")"

# (e) 起動に失敗(初回): 足したもの(unit・設定)は戻すが、/var/lib/openbao は残す(WIPE=0)
new_sandbox rollback
START_FAIL=1 run_setup
check "起動失敗は失敗扱い" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "失敗時も /var/lib/openbao は残す(wipe=0)" 1 "$(exists "$sb/root/var/lib/openbao")"
check "失敗時に初回に足した unit を戻す" 0 "$(exists "$sb/root/etc/systemd/system/openbao.service")"
check "失敗時に初回に足した設定を戻す" 0 "$(exists "$sb/root/etc/openbao/openbao.hcl")"
check "失敗時もステージを消す" 0 "$(exists "$sb/stage")"

# (f) 同じ失敗で wipe_data_on_failure=1: /var/lib/openbao を消す
new_sandbox wipe
START_FAIL=1 WIPE=1 run_setup
check "wipe=1 の失敗でデータを消す" 0 "$(exists "$sb/root/var/lib/openbao")"

# (g) ダウンロード失敗: 失敗扱い
new_sandbox curlfail
CURL_FAIL=1 run_setup
check "ダウンロード失敗は失敗扱い" 1 "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

echo
echo "結果: ok=$pass fail=$fails"
[ "$fails" -eq 0 ]
