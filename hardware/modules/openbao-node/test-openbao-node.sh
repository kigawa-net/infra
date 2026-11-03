#!/bin/bash
# modules/openbao-node のオフラインテスト。実機にも Bitwarden にも、ネットワークにも触れない。
#   bash hardware/modules/openbao-node/test-openbao-node.sh
#
# 1. files/openbao.hcl.tpl の描画(templatefile を、出力だけの一時的な root で評価する。provider は使わない)
# 2. files/openbao-node-setup.sh の挙動(OPENBAO_ROOT を一時ディレクトリにし、偽の curl / apt-get / dpkg / certbot / systemctl / useradd を使う)
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
# テスト用のダミー値。出力に現れてはいけない(トークンが echo されていないことを確認する)
TOKEN_VALUE="TOKEN-SECRET-7f3a"
FQDN="bao-02.kigawa.net"
PEER_FQDN="bao-03.kigawa.net"

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
# 1. config の描画(モジュールと同じく、自分自身を除いた peers を渡す)
# ---------------------------------------------------------------
render_dir="$work/render"
mkdir -p "$render_dir"
cat > "$render_dir/main.tf" <<EOF
locals {
  self_fqdn = "$FQDN"
  all_peers = [
    { fqdn = "$FQDN", address = "192.0.2.2" },
    { fqdn = "$PEER_FQDN", address = "192.0.2.3" },
  ]
}

output "rendered" {
  value = templatefile("$tpl", {
    fqdn       = local.self_fqdn
    node_id    = "bao-02"
    wg_address = "192.0.2.1"
    # modules/openbao-node/main.tf の retry_peers と同じ絞り込み(fqdn で自分を除く)
    peers = [for p in local.all_peers : p if p.fqdn != local.self_fqdn]
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
check "監査デバイス(file)が宣言されている" 1 "$(grep -c '^audit "file" "file"' "$conf")"
check "監査デバイス(syslog)が宣言されている" 1 "$(grep -c '^audit "syslog" "syslog"' "$conf")"
check "監査ログのパス" 1 "$(grep -c 'file_path *= *"/var/log/openbao/audit.log"' "$conf")"
check "監査デバイスは 2 つ以上(片方が書けなくても止まらない)" 1 "$([ "$(grep -c '^audit "' "$conf")" -ge 2 ] && echo 1 || echo 0)"
check "disable_mlock を書かない(2.x は mlock をやめた。書くと起動に失敗する)" 0 "$(grep -c "^[^#]*disable_mlock" "$conf")"
check "listener が 2 つ(WireGuard IP と loopback)" 2 "$(grep -c '^listener "tcp"' "$conf")"
check "WireGuard IP の 8200 / 8201 で待ち受ける" 1 "$(grep -c 'address *= *"192.0.2.1:8200"' "$conf")"
check "cluster_address も WireGuard IP" 1 "$(grep -c 'cluster_address *= *"192.0.2.1:8201"' "$conf")"
check "loopback の listener がある" 1 "$(grep -c 'address *= *"127.0.0.1:8200"' "$conf")"
check "tls_min_version は全 listener で tls13" 2 "$(grep -c 'tls_min_version *= *"tls13"' "$conf")"
check "公開 IF / 全アドレスに bind しない" 0 "$(grep -c '0\.0\.0\.0\|address *= *":' "$conf")"
check "listener の証明書パスは変えない" 2 "$(grep -c 'tls_cert_file *= *"/etc/openbao/tls/tls.crt"' "$conf")"
check "api_addr は fqdn の https(:8200)" 1 "$(grep -c "^api_addr *= *\"https://$FQDN:8200\"\$" "$conf")"
check "cluster_addr は WireGuard の 8201" 1 "$(grep -c '^cluster_addr *= *"https://192.0.2.1:8201"$' "$conf")"
check "node_id が設定されている" 1 "$(grep -c 'node_id *= *"bao-02"' "$conf")"
check "retry_join は他のノードだけ(1 件)" 1 "$(grep -c 'retry_join {' "$conf")"
check "retry_join の宛先は fqdn(bao-03)" 1 "$(grep -c "leader_api_addr *= *\"https://$PEER_FQDN:8200\"" "$conf")"
check "retry_join に自分の fqdn が無い" 0 "$(grep -c "leader_api_addr *= *\"https://$FQDN:8200\"" "$conf")"
check "retry_join に IP 直指定が無い" 0 "$(grep -c 'leader_api_addr *= *"https://192' "$conf")"
check "leader_ca_cert_file は無い(公開 CA)" 0 "$(grep -c 'leader_ca_cert_file *=' "$conf")"
check "ca.crt を参照しない" 0 "$(grep -c 'ca\.crt' "$conf")"
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
  start) [ -n "${FAKE_START_FAIL:-}" ] && exit 1; touch "$FAKE_STATE/active"; [ -n "${FAKE_DIE:-}" ] && rm -f "$FAKE_STATE/active"; exit 0 ;;
  stop) rm -f "$FAKE_STATE/active"; exit 0 ;;
esac
exit 0
EOF
# 偽の useradd: 呼び出しだけ記録
cat > "$work/fakebin/useradd" <<'EOF'
#!/bin/bash
echo "useradd $*" >> "$FAKE_LOG"
EOF
# 偽の dpkg: `dpkg -s` は、偽の apt-get install の印($FAKE_STATE/apt_installed)があるときだけ成功する
cat > "$work/fakebin/dpkg" <<'EOF'
#!/bin/bash
echo "dpkg $*" >> "$FAKE_LOG"
[ "$1" = "-s" ] && [ -f "$FAKE_STATE/apt_installed" ] && exit 0
exit 1
EOF
# 偽の apt-get: 呼び出しと DEBIAN_FRONTEND を記録。install で印を付ける
cat > "$work/fakebin/apt-get" <<'EOF'
#!/bin/bash
echo "apt-get $* DF=${DEBIAN_FRONTEND:-}" >> "$FAKE_LOG"
case " $* " in *" install "*) touch "$FAKE_STATE/apt_installed" ;; esac
exit 0
EOF
# 偽の certbot: 呼び出しを記録。certonly は $FAKE_LE/live/<fqdn> と renewal 設定を作り、delete で消す
# (FAKE_CERTBOT_FAIL で certonly を失敗させる)。引数に資格情報は含めない(ini のパスだけ)
cat > "$work/fakebin/certbot" <<'EOF'
#!/bin/bash
echo "certbot $*" >> "$FAKE_LOG"
case "$1" in
  certonly)
    [ -n "${FAKE_CERTBOT_FAIL:-}" ] && exit 1
    dom=""; prev=""
    for a in "$@"; do if [ "$prev" = "-d" ]; then dom="$a"; fi; prev="$a"; done
    server="https://acme-v02.api.letsencrypt.org/directory"
    case " $* " in *" --staging "*) server="https://acme-staging-v02.api.letsencrypt.org/directory" ;; esac
    mkdir -p "$FAKE_LE/live/$dom" "$FAKE_LE/renewal"
    suffix=""
    case " $* " in *" --staging "*) suffix="-STAGING" ;; esac
    echo "FULLCHAIN-$dom$suffix" > "$FAKE_LE/live/$dom/fullchain.pem"
    echo "PRIVKEY-$dom" > "$FAKE_LE/live/$dom/privkey.pem"
    printf 'server = %s\n' "$server" > "$FAKE_LE/renewal/$dom.conf"
    ;;
  delete)
    name=""; prev=""
    for a in "$@"; do if [ "$prev" = "--cert-name" ]; then name="$a"; fi; prev="$a"; done
    rm -rf "$FAKE_LE/live/$name" "$FAKE_LE/renewal/$name.conf"
    ;;
esac
exit 0
EOF
chmod +x "$work/fakebin"/*

# write_stage: Terraform が STAGE_DIR に置くもの(設定・unit・Cloudflare の ini・hosts の内容)
write_stage() {
  mkdir -p "$sb/stage"
  printf 'listener "tcp" {}\n' > "$sb/stage/openbao.hcl"
  printf '[Unit]\nDescription=test\n' > "$sb/stage/openbao.service"
  printf 'dns_cloudflare_api_token = %s\n' "$TOKEN_VALUE" > "$sb/stage/cloudflare.ini"
  printf '192.0.2.1 %s\n192.0.2.3 %s\n' "$FQDN" "$PEER_FQDN" > "$sb/stage/hosts.entries"
  printf '/var/log/openbao/audit.log {\n    daily\n}\n' > "$sb/stage/openbao.logrotate"
}
# new_sandbox <name>: sandbox を作り、既存の /etc/hosts(無関係な行を含む)と stage を置く
new_sandbox() {
  sb="$work/sb-$1"
  mkdir -p "$sb/root/etc" "$sb/state"
  printf '127.0.0.1 localhost\n' > "$sb/root/etc/hosts"
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
    OPENBAO_ROOT="$sb/root" OPENBAO_START_WAIT=0 OPENBAO_VERSION=2.1.0 DEB_URL="https://example.invalid/bao.deb" \
    DEB_SHA256="${DEB_SHA256_OVERRIDE:-$deb_sha}" STAGE_DIR="$sb/stage" \
    WIPE_DATA_ON_FAILURE="${WIPE:-0}" FAKE_DEB="$work/bao.deb" FAKE_LOG="$FAKE_LOG" FAKE_STATE="$sb/state" \
    FAKE_CURL_FAIL="${CURL_FAIL:-}" FAKE_START_FAIL="${START_FAIL:-}" FAKE_DIE="${DIE_AFTER_START:-}" \
    FAKE_LE="$sb/root/etc/letsencrypt" FAKE_CERTBOT_FAIL="${CERTBOT_FAIL:-}" \
    FQDN="$FQDN" ACME_EMAIL="${EMAIL:-}" ACME_STAGING="${STAGING:-0}" \
    bash "$setup" >"$last_out" 2>&1
  rc=$?
  cp "$FAKE_LOG" "$sb/run$run_n.calls"
}

exists() { if [ -e "$1" ]; then echo 1; else echo 0; fi; }
failed() { if [ "$rc" -ne 0 ]; then echo 1; else echo 0; fi; }
# hosts に、管理ブロックの開始行がいくつあるか
hosts_block_count() { grep -c '^# BEGIN openbao-node' "$sb/root/etc/hosts"; }
# sandbox ごとの置き場所(new_sandbox の後で使う)
set_paths() {
  live="$sb/root/etc/letsencrypt/live/$FQDN"
  hook="$sb/root/etc/letsencrypt/renewal-hooks/deploy/openbao-tls.sh"
}

# (a) 初回構築: 成功し、証明書を発行して OpenBao に配り、起動する。operator init は呼ばれない
new_sandbox first
set_paths
run_setup
calls="$sb/run$run_n.calls"
check "初回構築が成功する" 0 "$rc"
check "bao バイナリが配置される" 1 "$(exists "$sb/root/usr/local/bin/bao")"
check "apt で certbot と cloudflare プラグインを入れる(初回のみ)" 1 "$(grep -c '^apt-get install .*certbot python3-certbot-dns-cloudflare' "$calls")"
check "apt は DEBIAN_FRONTEND=noninteractive" 2 "$(grep -c 'DF=noninteractive' "$calls")"
check "cloudflare.ini は 0600" 600 "$(stat -c %a "$sb/root/etc/letsencrypt/cloudflare.ini" 2>/dev/null)"
check "cloudflare.ini の中身はトークン 1 行" 1 "$(grep -c "^dns_cloudflare_api_token = $TOKEN_VALUE\$" "$sb/root/etc/letsencrypt/cloudflare.ini" 2>/dev/null)"
check "証明書を発行する(初回)" 1 "$(grep -c '^certbot certonly' "$calls")"
check "certonly は dns-cloudflare・資格情報・fqdn・非対話" 1 "$(grep -c "^certbot certonly --dns-cloudflare --dns-cloudflare-credentials $sb/root/etc/letsencrypt/cloudflare.ini -d $FQDN --non-interactive --agree-tos --register-unsafely-without-email\$" "$calls")"
check "メール未指定なら --register-unsafely-without-email" 0 "$(grep -c -- '--email' "$calls")"
check "本番では --staging を付けない" 0 "$(grep -c -- '--staging' "$calls")"
check "certbot の引数にトークンを含めない" 0 "$(grep -c "$TOKEN_VALUE" "$calls")"
check "fullchain を tls.crt に配る(0600)" 600 "$(stat -c %a "$sb/root/etc/openbao/tls/tls.crt" 2>/dev/null)"
check "tls.crt の中身は fullchain" "FULLCHAIN-$FQDN" "$(cat "$sb/root/etc/openbao/tls/tls.crt" 2>/dev/null)"
check "privkey を tls.key に配る(0600)" 600 "$(stat -c %a "$sb/root/etc/openbao/tls/tls.key" 2>/dev/null)"
check "tls.key の中身は privkey" "PRIVKEY-$FQDN" "$(cat "$sb/root/etc/openbao/tls/tls.key" 2>/dev/null)"
check "deploy hook は 0755" 755 "$(stat -c %a "$hook" 2>/dev/null)"
check "deploy hook は、この fqdn の更新だけを扱う" 1 "$(grep -c "\[ \"\$(basename \"\${RENEWED_LINEAGE:-}\")\" = \"$FQDN\" \] || exit 0" "$hook" 2>/dev/null)"
check "deploy hook は tls.crt / tls.key を 0600 で配る" 2 "$(grep -c "install -m 0600" "$hook" 2>/dev/null)"
check "deploy hook は起動中なら systemctl reload openbao" 1 "$(grep -c 'systemctl reload openbao' "$hook" 2>/dev/null)"
check "deploy hook に秘密鍵の内容・PEM を含めない" 0 "$(grep -c 'PRIVKEY-\|PRIVATE' "$hook" 2>/dev/null)"
check "certbot.timer を有効にする" 1 "$(grep -c '^systemctl enable --now certbot.timer' "$calls")"
check "hosts: 管理ブロックが 1 つ" 1 "$(hosts_block_count)"
check "hosts: 自分の fqdn を WireGuard の IP に向ける" 1 "$(grep -c "^192.0.2.1 $FQDN\$" "$sb/root/etc/hosts")"
check "hosts: peer の fqdn を WireGuard の IP に向ける" 1 "$(grep -c "^192.0.2.3 $PEER_FQDN\$" "$sb/root/etc/hosts")"
check "hosts: 既存の行を残す" 1 "$(grep -c '^127.0.0.1 localhost$' "$sb/root/etc/hosts")"
check "設定は配置される" 1 "$(exists "$sb/root/etc/openbao/openbao.hcl")"
check "unit は配置される" 1 "$(exists "$sb/root/etc/systemd/system/openbao.service")"
check "logrotate の設定が配置される" 1 "$(exists "$sb/root/etc/logrotate.d/openbao")"
check "/var/lib/openbao が作られる" 1 "$(exists "$sb/root/var/lib/openbao")"
check "start が呼ばれる" 1 "$(grep -c '^systemctl start openbao' "$calls")"
check "証明書の発行は start より前" 1 "$(c=$(grep -n '^certbot certonly' "$calls" | cut -d: -f1); s=$(grep -n '^systemctl start openbao' "$calls" | cut -d: -f1); [ -n "$c" ] && [ -n "$s" ] && [ "$c" -lt "$s" ] && echo 1 || echo 0)"
check "operator init は呼ばれない" 0 "$(grep -c '^bao operator' "$calls")"
check "ステージ(トークンを含む)は消される" 0 "$(exists "$sb/stage")"
hosts_sum_before=$(sha256sum < "$sb/root/etc/hosts")

# (b) 再実行(変更なし): 証明書は発行し直さない。apt・hosts・再起動・再読込もしない
write_stage
run_setup
calls="$sb/run$run_n.calls"
check "変更なしの再実行は成功する" 0 "$rc"
check "証明書がある間は発行しない" 0 "$(grep -c '^certbot certonly' "$calls")"
check "証明書を削除もしない" 0 "$(grep -c '^certbot delete' "$calls")"
check "certbot 導入済みなら apt を呼ばない" 0 "$(grep -c '^apt-get install' "$calls")"
check "hosts は内容が同じなら変えない" "$hosts_sum_before" "$(sha256sum < "$sb/root/etc/hosts")"
check "hosts の管理ブロックは 1 つのまま" 1 "$(hosts_block_count)"
check "変更なしなら restart しない" 0 "$(grep -c 'systemctl restart' "$calls")"
check "変更なしなら reload もしない" 0 "$(grep -c 'systemctl reload' "$calls")"

# (c) 証明書の更新(certbot が deploy hook を呼ぶ想定): 配置先を更新し、起動中なら SIGHUP のみ
printf 'FULLCHAIN-RENEWED\n' > "$live/fullchain.pem"
printf 'PRIVKEY-RENEWED\n' > "$live/privkey.pem"
touch "$sb/state/active"
: > "$FAKE_LOG"
env -i PATH="$work/fakebin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  RENEWED_LINEAGE="$live" OPENBAO_TLS_DIR="$sb/root/etc/openbao/tls" \
  FAKE_LOG="$sb/calls-hook" FAKE_STATE="$sb/state" bash "$hook" >"$sb/hook.out" 2>&1
hook_rc=$?
last_out="$sb/hook.out"
check "deploy hook は成功する" 0 "$hook_rc"
check "更新後の tls.crt が新しい内容" "FULLCHAIN-RENEWED" "$(cat "$sb/root/etc/openbao/tls/tls.crt")"
check "更新後の tls.key が新しい内容" "PRIVKEY-RENEWED" "$(cat "$sb/root/etc/openbao/tls/tls.key")"
check "更新後も tls.key は 0600" 600 "$(stat -c %a "$sb/root/etc/openbao/tls/tls.key")"
check "証明書の更新は reload(SIGHUP)" 1 "$(grep -c '^systemctl reload openbao' "$sb/calls-hook")"
check "証明書の更新では restart しない" 0 "$(grep -c 'systemctl restart' "$sb/calls-hook")"
# 別の lineage(この node の証明書ではない)の更新では、何も配らない
rm -f "$sb/calls-hook"
printf 'FULLCHAIN-OTHER\n' > "$live/fullchain.pem"
env -i PATH="$work/fakebin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  RENEWED_LINEAGE="$sb/root/etc/letsencrypt/live/other.kigawa.net" OPENBAO_TLS_DIR="$sb/root/etc/openbao/tls" \
  FAKE_LOG="$sb/calls-hook" FAKE_STATE="$sb/state" bash "$hook" >/dev/null 2>&1
check "別の lineage の更新では tls.crt を変えない" "FULLCHAIN-RENEWED" "$(cat "$sb/root/etc/openbao/tls/tls.crt")"
check "別の lineage の更新では reload しない" 0 "$(cat "$sb/calls-hook" 2>/dev/null | grep -c systemctl)"
rm -f "$sb/state/active"

# (d) SHA256 が一致しない: 何も配置せず失敗する(証明書の発行にも進まない)
new_sandbox badsha
DEB_SHA256_OVERRIDE=$(printf '%064d' 0) run_setup
check "SHA256 不一致は失敗する" 1 "$(failed)"
check "SHA256 不一致では bao を配置しない" 0 "$(exists "$sb/root/usr/local/bin/bao")"
check "SHA256 不一致では証明書を発行しない" 0 "$(grep -c '^certbot' "$sb/run$run_n.calls")"

# (e) 起動に失敗(初回): 足したもの(unit・設定)は戻すが、/var/lib/openbao は残す(WIPE=0)
new_sandbox rollback
START_FAIL=1 run_setup
check "起動失敗は失敗扱い" 1 "$(failed)"
check "失敗時も /var/lib/openbao は残す(wipe=0)" 1 "$(exists "$sb/root/var/lib/openbao")"
check "失敗時に初回に足した unit を戻す" 0 "$(exists "$sb/root/etc/systemd/system/openbao.service")"
check "失敗時に初回に足した設定を戻す" 0 "$(exists "$sb/root/etc/openbao/openbao.hcl")"
check "失敗時もステージを消す" 0 "$(exists "$sb/stage")"

# (e2) start は成功するが、直後に落ちる(2.7.2 の disable_mlock など、設定エラー)。失敗扱いにする
new_sandbox diedafterstart
DIE_AFTER_START=1 run_setup
check "start の直後に落ちたら、失敗扱い" 1 "$(failed)"
check "落ちたときの失敗メッセージ" 1 "$(grep -c '起動後に OpenBao が止まりました' "$last_out")"

# (f) 同じ失敗で wipe_data_on_failure=1: /var/lib/openbao を消す
new_sandbox wipe
START_FAIL=1 WIPE=1 run_setup
check "wipe=1 の失敗でデータを消す" 0 "$(exists "$sb/root/var/lib/openbao")"

# (g) ダウンロード失敗: 失敗扱い
new_sandbox curlfail
CURL_FAIL=1 run_setup
check "ダウンロード失敗は失敗扱い" 1 "$(failed)"

# (h) 証明書の発行に失敗: 失敗扱い。OpenBao は起動せず、TLS の配置もしない
new_sandbox certfail
CERTBOT_FAIL=1 run_setup
check "発行失敗は失敗扱い" 1 "$(failed)"
check "発行失敗では start しない" 0 "$(grep -c '^systemctl start' "$sb/run$run_n.calls")"
check "発行失敗では tls.crt を置かない" 0 "$(exists "$sb/root/etc/openbao/tls/tls.crt")"
check "発行失敗では tls.key を置かない" 0 "$(exists "$sb/root/etc/openbao/tls/tls.key")"

# (i) staging: 連絡先メールと --staging を付けて発行する。本番に切り替えたら発行し直す
new_sandbox staging
EMAIL=ops@example.invalid STAGING=1 run_setup
check "staging の実行は成功する" 0 "$rc"
check "staging では --staging を付ける" 1 "$(grep -c -- '--staging' "$sb/run$run_n.calls")"
check "連絡先メールを --email で渡す" 1 "$(grep -c -- '--email ops@example.invalid' "$sb/run$run_n.calls")"
check "メール指定時は --register-unsafely-without-email を付けない" 0 "$(grep -c -- '--register-unsafely-without-email' "$sb/run$run_n.calls")"
check "staging の証明書が OpenBao に配られる" "FULLCHAIN-$FQDN-STAGING" "$(cat "$sb/root/etc/openbao/tls/tls.crt")"
write_stage
EMAIL=ops@example.invalid STAGING=1 run_setup
check "staging のままの再実行は成功する" 0 "$rc"
check "staging のままの再実行は発行し直さない" 0 "$(grep -c '^certbot certonly' "$sb/run$run_n.calls")"
write_stage
STAGING=0 run_setup
check "本番へ切り替えたら成功する" 0 "$rc"
check "本番へ切り替えたら既存を削除する" 1 "$(grep -c '^certbot delete --cert-name '"$FQDN" "$sb/run$run_n.calls")"
check "本番へ切り替えたら本番で発行し直す" 1 "$(grep -c '^certbot certonly' "$sb/run$run_n.calls")"
check "本番の発行には --staging を付けない" 0 "$(grep -c -- '--staging' "$sb/run$run_n.calls")"
check "切り替え後の tls.crt は本番の内容" "FULLCHAIN-$FQDN" "$(cat "$sb/root/etc/openbao/tls/tls.crt")"

# (j) トークンは出力・呼び出し記録に出ない(ini ファイルだけに入る)
leaks=$(cat "$work"/sb-*/run*.out "$work"/sb-*/run*.calls "$work"/sb-*/hook.out "$work"/sb-*/calls-hook 2>/dev/null | grep -c "$TOKEN_VALUE")
check "トークンが出力・呼び出し記録に現れない" 0 "$leaks"

echo
echo "結果: ok=$pass fail=$fails"
[ "$fails" -eq 0 ]
