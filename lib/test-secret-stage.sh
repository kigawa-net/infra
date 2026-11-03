#!/bin/bash
# lib/secret-stage.sh のテスト(tmpfs の置き場所は、一時ディレクトリに向ける。偽の sudo を使う。実機には触れない)。
#   bash lib/test-secret-stage.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STAGE="$here/secret-stage.sh"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
ng() { fail=$((fail + 1)); echo "FAIL - $1"; }
chk() { if ( eval "$2" ); then ok "$1"; else ng "$1"; fi; }

mksb() {
  sb=$(mktemp -d)
  export SECRET_STAGE_DIR="$sb/stage"
  export SECRET_STAGE_LEGACY="$sb/legacy1 $sb/legacy2"
  : > "$sb/legacy1"
  : > "$sb/legacy2"
  mkdir -p "$sb/bin"
}

# ---- 1. prepare: ディレクトリ 0700、名前のファイルは 0600 の空。前回の残骸と、古い置き場所を消す ----
mksb
mkdir -p "$SECRET_STAGE_DIR"
echo "LEFTOVER-SECRET" > "$SECRET_STAGE_DIR/shutdown.key"
bash "$STAGE" prepare shutdown.key sudo-pass; rc=$?
chk "prepare: 成功" '[ "$rc" = 0 ]'
chk "prepare: 前回の残骸(秘密)を消し、名前のファイルは空・0600" '[ -z "$(cat "$SECRET_STAGE_DIR/shutdown.key")" ] && [ "$(stat -c %a "$SECRET_STAGE_DIR/shutdown.key")" = 600 ] && [ "$(stat -c %a "$SECRET_STAGE_DIR")" = 700 ]'
chk "prepare: 古い置き場所を消す" '[ ! -e "$sb/legacy1" ] && [ ! -e "$sb/legacy2" ]'
rm -rf "$sb"

# ---- 2. 途中で失敗した apply の残骸(接続が切れた想定)を、次の prepare が消す ----
mksb
mkdir -p "$SECRET_STAGE_DIR"
printf 'X' > "$SECRET_STAGE_DIR/auth-token"
bash "$STAGE" prepare; rc=$?
chk "残骸: 次の prepare で消える" '[ "$rc" = 0 ] && [ ! -e "$SECRET_STAGE_DIR/auth-token" ]'
rm -rf "$sb"

# ---- 3. run: 成功でも失敗でも、終了コードを保って、必ず消す ----
mksb
bash "$STAGE" prepare key
bash "$STAGE" run -- sh -c 'test -e "$SECRET_STAGE_DIR/key"'; rc=$?
chk "run 成功: 終了コード 0 で、置き場所を消す" '[ "$rc" = 0 ] && [ ! -e "$SECRET_STAGE_DIR" ]'
bash "$STAGE" prepare key
bash "$STAGE" run -- sh -c 'exit 3'; rc=$?
chk "run 失敗: 終了コード 3 を保ち、置き場所を消す" '[ "$rc" = 3 ] && [ ! -e "$SECRET_STAGE_DIR" ]'
bash "$STAGE" prepare key
bash "$STAGE" run -- false; rc=$?
chk "run 失敗(false): 終了コード 1 を保ち、置き場所を消す(インストーラの ABORT の想定)" '[ "$rc" = 1 ] && [ ! -e "$SECRET_STAGE_DIR/key" ]'
bash "$STAGE" run; rc=$?
chk "run: -- が無いと、使い方のエラー(2)" '[ "$rc" = 2 ]'
rm -rf "$sb"

# ---- 3b. 回帰: インストーラが ABORT(一部だけの設定)しても、置き場所の秘密は残らない ----
INSTALL="$here/../hardware/modules/maas-rack/files/maas-wol-webhook-install.sh"
mksb
bash "$STAGE" prepare shutdown.key auth-token sudo-pass
printf 'SECRET-KEY-MATERIAL' > "$SECRET_STAGE_DIR/shutdown.key"
printf 'SECRET-TOKEN-MATERIAL' > "$SECRET_STAGE_DIR/auth-token"
printf 'x\n' > "$sb/src.py"
# 鍵だけ(表と known_hosts が無い)。install は ABORT する。インストール先は、すべて一時ディレクトリ
bash "$STAGE" run -- env BCAST=192.168.1.255 SRC="$sb/src.py" SBIN_DIR="$sb/sbin" UNIT_DIR="$sb/units" CONF_DIR="$sb/conf" \
  SHUTDOWN_KEY_SRC="$SECRET_STAGE_DIR/shutdown.key" SHUTDOWN_AUTH_TOKEN_SRC="$SECRET_STAGE_DIR/auth-token" bash "$INSTALL" > "$sb/out" 2>&1; rc=$?
chk "回帰: 一部だけで ABORT(終了コード 1)" '[ "$rc" = 1 ] && grep -q "4 つそろえる" "$sb/out"'
chk "回帰: ABORT の後も、秘密の置き場所を消している" '[ ! -e "$SECRET_STAGE_DIR" ]'
chk "回帰: ABORT の後も、設定ディレクトリに秘密を置いていない" '[ ! -e "$sb/conf/shutdown.key" ] && [ ! -e "$sb/conf/auth-token" ]'
rm -rf "$sb"

# ---- 4. clean: 置き場所と古い置き場所を消す(冪等) ----
mksb
bash "$STAGE" prepare key
bash "$STAGE" clean; rc=$?
bash "$STAGE" clean; rc2=$?
chk "clean: 2 回実行しても成功し、どちらも消える" '[ "$rc" = 0 ] && [ "$rc2" = 0 ] && [ ! -e "$SECRET_STAGE_DIR" ] && [ ! -e "$sb/legacy1" ]'
rm -rf "$sb"

# ---- 5. 偽の sudo -S(パスワードを、最初の 1 行として標準入力から読む)で、パスワードの引用符を検査 ----
# 本番の形: sudo -S ... secret-stage.sh run -- <cmd> < パスワードのファイル
# パスワードが argv に出ないこと、パスワードの中の '; echo PWNED; # が実行されないこと、を確かめる。
mksb
cat > "$sb/bin/sudo" <<'FAKE'
#!/bin/bash
echo "$*" >> "$F/argv"
IFS= read -r pw
printf '%s' "$pw" > "$F/got-pw"
[ "$1" = -S ] && shift
exec "$@"
FAKE
chmod +x "$sb/bin/sudo"
PW="x'; echo PWNED; #"
printf '%s\n' "$PW" > "$sb/sudo-pass"
chmod 0600 "$sb/sudo-pass"
out=$(F="$sb" PATH="$sb/bin:$PATH" sudo -S bash "$STAGE" run -- sh -c 'echo ran' < "$sb/sudo-pass" 2>&1)
chk "パスワードの引用符: 実行されるのは、指定したコマンドだけ(PWNED が出ない)" '[ "$out" = "ran" ] && ! printf "%s" "$out" | grep -q PWNED'
chk "パスワードの引用符: パスワードは、そのまま sudo に渡る" '[ "$(cat "$sb/got-pw")" = "$PW" ]'
chk "パスワードの引用符: パスワードが argv に出ない" '! grep -q PWNED "$sb/argv" && ! grep -qF "x'"'"'" "$sb/argv"'
rm -rf "$sb"

# ---- 6. root で run したとき、置いたファイルを root 所有にする(偽の chown で確認。ディレクトリは触らない)----
mksb
bash "$STAGE" prepare key sudo-pass
printf 'S' > "$SECRET_STAGE_DIR/key"
cat > "$sb/bin/chown" <<'FAKE'
#!/bin/bash
echo "chown $*" >> "$F/chown.log"
FAKE
chmod +x "$sb/bin/chown"
F="$sb" SECRET_STAGE_UID=0 SECRET_STAGE_CHOWN="$sb/bin/chown" bash "$STAGE" run -- true; rc=$?
chk "root で run: 置いたファイルの所有者を root:root にした(ディレクトリは対象外)" '[ "$rc" = 0 ] && grep -q "^chown root:root .*key" "$sb/chown.log" && grep -q "^chown root:root .*sudo-pass" "$sb/chown.log" && ! grep -q "stage$" "$sb/chown.log"'
mksb
bash "$STAGE" prepare key
F="$sb" SECRET_STAGE_UID=1000 SECRET_STAGE_CHOWN="$sb/bin/chown" bash "$STAGE" run -- true
chk "ssh ユーザーで run: chown しない" '[ ! -e "$sb/chown.log" ]'
rm -rf "$sb"

# ---- 7. 静的な確認 ----
chk "構文" 'bash -n "$STAGE"'

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
