#!/bin/bash
# files/maas-shutdown-setup.sh のテスト(偽の id / useradd / usermod / userdel / visudo / chown を使い、ROOT を一時ディレクトリに向ける)。実機には触れない。
#   bash hardware/k8s-worker5/test-maas-shutdown-target.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$here/files/maas-shutdown-setup.sh"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
ng() { fail=$((fail + 1)); echo "FAIL - $1"; [ -f "${sb:-/nonexistent}/out" ] && tail -6 "$sb/out" | sed 's/^/       | /'; }
chk() { if ( eval "$2" ); then ok "$1"; else ng "$1"; fi; }

KEY_OK="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYKEYFORTESTONLY maas-test"
FROM_OK="192.168.1.20,192.168.1.120"
EXP_LINE="restrict,from=\"$FROM_OK\",command=\"/usr/bin/sudo -n /usr/sbin/shutdown -h now\" $KEY_OK"

# 偽のコマンド。環境変数(F、VISUDO_FAIL)は、実行のときに読む(quoted heredoc)
mksb() {
  sb=$(mktemp -d)
  mkdir -p "$sb/bin" "$sb/root"
  : > "$sb/calls"
  cat > "$sb/bin/id" <<'FAKE'
#!/bin/bash
[ -e "$F/user" ] && exit 0
exit 1
FAKE
  cat > "$sb/bin/useradd" <<'FAKE'
#!/bin/bash
echo "useradd $*" >> "$F/calls"
touch "$F/user"
FAKE
  cat > "$sb/bin/usermod" <<'FAKE'
#!/bin/bash
echo "usermod $*" >> "$F/calls"
FAKE
  cat > "$sb/bin/userdel" <<'FAKE'
#!/bin/bash
echo "userdel $*" >> "$F/calls"
rm -f "$F/user"
FAKE
  cat > "$sb/bin/chown" <<'FAKE'
#!/bin/bash
echo "chown $*" >> "$F/calls"
FAKE
  # visudo -cf <file>: VISUDO_FAIL=1 なら失敗。そうでなければ、期待する 1 行だけを、正しいとみなす
  cat > "$sb/bin/visudo" <<'FAKE'
#!/bin/bash
echo "visudo $*" >> "$F/calls"
[ "${VISUDO_FAIL:-0}" = 1 ] && exit 1
f="${!#}"
grep -qxF 'maas-shutdown ALL=(root) NOPASSWD: /usr/sbin/shutdown -h now' "$f" || exit 1
exit 0
FAKE
  chmod +x "$sb"/bin/*
  AK="$sb/root/home/maas-shutdown/.ssh/authorized_keys"
  SUDOERS="$sb/root/etc/sudoers.d/maas-shutdown"
}

# 引数: 公開鍵、from、追加の環境変数(KEY=VAL ...)。env -i で、呼び出し元の環境を持ち込まない
run() {
  local key=$1 from=$2
  shift 2
  env -i PATH=/usr/bin:/bin F="$sb" EXTRA_PATH="$sb/bin" ROOT="$sb/root" \
    MAAS_SHUTDOWN_PUBLIC_KEY="$key" MAAS_SHUTDOWN_ALLOWED_FROM="$from" "$@" bash "$SCRIPT" > "$sb/out" 2>&1
}

# ---- 1. 初回: 受け口を作る ----
mksb
run "$KEY_OK" "$FROM_OK"; rc=$?
chk "初回: 終了コード 0" '[ "$rc" = 0 ]'
chk "初回: authorized_keys の 1 行が、from と forced command の付きの形" '[ "$(cat "$AK")" = "$EXP_LINE" ]'
chk "初回: authorized_keys は 0600、.ssh は 0700" '[ "$(stat -c %a "$AK")" = 600 ] && [ "$(stat -c %a "$sb/root/home/maas-shutdown/.ssh")" = 700 ]'
chk "初回: sudoers は 0440 で、shutdown -h now だけ" '[ "$(stat -c %a "$SUDOERS")" = 440 ] && [ "$(cat "$SUDOERS")" = "maas-shutdown ALL=(root) NOPASSWD: /usr/sbin/shutdown -h now" ]'
chk "初回: sudoers を、置く前に visudo で検証した" 'grep -q "^visudo -cf " "$sb/calls"'
chk "初回: ユーザーは、システムユーザーではなく、/bin/sh・パスワードはロック" 'grep -q "^useradd -m -s /bin/sh " "$sb/calls" && ! grep -q -- "--system" "$sb/calls" && grep -qx "usermod -s /bin/sh -L maas-shutdown" "$sb/calls"'
chk "初回: authorized_keys と .ssh の所有者を、maas-shutdown にした" 'grep -q "^chown maas-shutdown:maas-shutdown " "$sb/calls"'
chk "初回: 一時ファイルを残さない(sudoers.d に、ドットのファイルが無い)" '[ -z "$(ls -A "$sb/root/etc/sudoers.d" | grep "^\\." || true)" ]'
chk "初回: 出力に、公開鍵の中身を出さない(公開鍵は、ここでは秘密ではないが、ログの形を確認)" 'grep -q "受け口を設定した" "$sb/out"'
rm -rf "$sb"

# ---- 2. 冪等: 2 回目は、同じ内容になり、行が増えない ----
mksb
run "$KEY_OK" "$FROM_OK" >/dev/null
run "$KEY_OK" "$FROM_OK"; rc=$?
chk "冪等: 2 回目も成功し、authorized_keys の行は 1 行のまま" '[ "$rc" = 0 ] && [ "$(wc -l < "$AK")" = 1 ] && [ "$(cat "$AK")" = "$EXP_LINE" ]'
chk "冪等: 2 回目は useradd しない(既にいる)" '[ "$(grep -c "^useradd" "$sb/calls")" = 1 ]'
rm -rf "$sb"

# ---- 3. 公開鍵の検証(改行・オプションの注入を拒否。何も作らない) ----
for bad in \
  "$(printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMY\nno-pty ssh-ed25519 AAAA evil')" \
  "$(printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMY\rx')" \
  'restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMY maas-test' \
  'command="/bin/sh" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMY' \
  'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDUMMY maas-test' \
  'ssh-ed25519 AAAA"x" maas-test' \
  'ssh-ed25519 AAAA;id maas-test' \
  'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMY maas-test,from=*'; do
  mksb
  run "$bad" "$FROM_OK"; rc=$?
  label=$(printf '%s' "$bad" | tr '\n\r' '__' | cut -c1-40)
  chk "公開鍵の拒否: $label" '[ "$rc" = 1 ] && grep -q "ABORT" "$sb/out" && [ ! -s "$sb/calls" ] && [ ! -e "$AK" ] && [ ! -e "$SUDOERS" ]'
  rm -rf "$sb"
done

# ---- 4. from の検証(空、不正な IPv4 は中止) ----
mksb
run "$KEY_OK" ""; rc=$?
chk "from が空: ABORT し、何も作らない(from の無い鍵は作らない)" '[ "$rc" = 1 ] && grep -q "from の無い鍵" "$sb/out" && [ ! -s "$sb/calls" ] && [ ! -e "$AK" ]'
rm -rf "$sb"
for bad in "192.168.1.256" "192.168.1.20;id" "192.168.1" "-oProxyCommand=x" "192.168.1.20,,192.168.1.120" "192.168.1.20 "; do
  mksb
  run "$KEY_OK" "$bad"; rc=$?
  chk "from の拒否: [$bad]" '[ "$rc" = 1 ] && [ ! -e "$AK" ] && [ ! -e "$SUDOERS" ]'
  rm -rf "$sb"
done

# ---- 5. sudoers の検証に失敗: 既存の sudoers を壊さない ----
mksb
mkdir -p "$sb/root/etc/sudoers.d"
echo "OLD-SUDOERS-LINE" > "$SUDOERS"
run "$KEY_OK" "$FROM_OK" VISUDO_FAIL=1; rc=$?
chk "sudoers の検証失敗: ABORT" '[ "$rc" = 1 ] && grep -q "sudoers の検証に失敗" "$sb/out"'
chk "sudoers の検証失敗: 既存の sudoers はそのまま" '[ "$(cat "$SUDOERS")" = "OLD-SUDOERS-LINE" ]'
chk "sudoers の検証失敗: authorized_keys を作っていない(検証の後に置く)" '[ ! -e "$AK" ]'
chk "sudoers の検証失敗: 一時ファイルを残さない" '[ -z "$(ls -A "$sb/root/etc/sudoers.d" | grep "^\\." || true)" ]'
rm -rf "$sb"

# ---- 6. 無効化(公開鍵が空): sudoers と、ユーザーを消す ----
mksb
run "$KEY_OK" "$FROM_OK" >/dev/null
run "" ""; rc=$?
chk "無効化: 成功し、sudoers を消し、ユーザーを削除した" '[ "$rc" = 0 ] && [ ! -e "$SUDOERS" ] && grep -q "^userdel -r maas-shutdown" "$sb/calls" && [ ! -e "$sb/user" ]'
chk "無効化: 出力に、受け口の削除を表示" 'grep -q "受け口を削除" "$sb/out"'
rm -rf "$sb"

mksb
run "" ""; rc=$?
chk "無効化(何も無い): 成功(冪等)。userdel を呼ばない" '[ "$rc" = 0 ] && [ ! -s "$sb/calls" ]'
rm -rf "$sb"

# ---- 7. 静的な確認 ----
chk "構文" 'bash -n "$SCRIPT"'
chk "forced command は、sudo -n で shutdown -h now だけ(リモートコマンドは、クライアントが指定できない)" 'grep -qF '"'"'command=\"/usr/bin/sudo -n /usr/sbin/shutdown -h now\"'"'"' "$SCRIPT"'

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
