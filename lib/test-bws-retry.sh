#!/usr/bin/env bash
# lib/bws-retry.sh のテスト。偽の bws を PATH の先頭に置いて挙動を確認する(実際の Bitwarden には接続しない)。
# 使い方: bash lib/test-bws-retry.sh
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 偽 bws: $FAKE_MODE と呼び出し回数(カウンタファイル)で挙動を切り替える
cat >"$tmp/bws" <<'FAKE'
#!/usr/bin/env bash
n=$(cat "$FAKE_COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" >"$FAKE_COUNT"
case "$FAKE_MODE" in
  ok) echo '{"value":"abc123"}' ;;
  flaky) # 最初の FAKE_FAILS 回は 503、その後成功
    if [ "$n" -le "${FAKE_FAILS:-2}" ]; then
      echo "Error: 0: Received error message from server: [503 Service Unavailable] upstream connect error or disconnect/reset before headers. reset reason: connection timeout" >&2
      exit 1
    fi
    echo '{"value":"abc123"}' ;;
  always503)
    echo "Error: [503 Service Unavailable] connection timeout" >&2
    exit 1 ;;
  notfound)
    echo "Error: Resource not found" >&2
    exit 1 ;;
  empty) echo '{"value":""}' ;;
  null) echo '{"value":null}' ;;
esac
FAKE
chmod +x "$tmp/bws"
export PATH="$tmp:$PATH"
export FAKE_COUNT="$tmp/count"
export BWS_RETRY_SLEEP=0

# shellcheck source=bws-retry.sh
source "$here/bws-retry.sh"

pass=0
fail=0
check() { # check <name> <expected-stdout> <expected-rc> <expected-calls> <actual-stdout> <actual-rc>
  local name="$1" exp_out="$2" exp_rc="$3" exp_calls="$4" act_out="$5" act_rc="$6" calls
  calls=$(cat "$FAKE_COUNT" 2>/dev/null || echo 0)
  if [ "$act_out" = "$exp_out" ] && [ "$act_rc" = "$exp_rc" ] && [ "$calls" = "$exp_calls" ]; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name (stdout='$act_out' rc=$act_rc calls=$calls; expected stdout='$exp_out' rc=$exp_rc calls=$exp_calls)"
    fail=$((fail + 1))
  fi
}
run() { # run <mode> [fails]  -> sets out/rc, resets counter
  rm -f "$FAKE_COUNT"
  FAKE_MODE="$1" FAKE_FAILS="${2:-2}" bash -c 'source "$1"; bws_get_value some-id' _ "$here/bws-retry.sh" >"$tmp/stdout" 2>"$tmp/stderr"
  rc=$?
  out=$(cat "$tmp/stdout")
}

run ok;               check "成功(1回目)"                    "abc123" 0 1 "$out" "$rc"
run flaky 2;          check "503 を2回 → 3回目で成功"         "abc123" 0 3 "$out" "$rc"
run flaky 4;          check "503 を4回 → 5回目で成功"         "abc123" 0 5 "$out" "$rc"
run always503;        check "503 が続く → 5回で諦める"         ""       1 5 "$out" "$rc"
grep -q "failed after 5 attempts" "$tmp/stderr" && { echo "PASS: 諦めたときのメッセージ"; pass=$((pass + 1)); } || { echo "FAIL: 諦めたときのメッセージ"; fail=$((fail + 1)); }
run notfound;         check "未存在は再試行しない(1回で失敗)"   ""       1 1 "$out" "$rc"
run empty;            check "値が空 → 即失敗"                ""       1 1 "$out" "$rc"
run null;             check "値が null → 即失敗"             ""       1 1 "$out" "$rc"

# 値は標準エラーに出ない
run flaky 1
if grep -q "abc123" "$tmp/stderr"; then echo "FAIL: 値が標準エラーに出ている"; fail=$((fail + 1)); else echo "PASS: 値は標準エラーに出ない"; pass=$((pass + 1)); fi

# set -euo pipefail 下でも動く
rm -f "$FAKE_COUNT"
res=$(FAKE_MODE=flaky FAKE_FAILS=1 bash -c 'set -euo pipefail; source "$1"; v=$(bws_get_value some-id); echo "got:$v"' _ "$here/bws-retry.sh" 2>/dev/null)
[ "$res" = "got:abc123" ] && { echo "PASS: set -euo pipefail 下"; pass=$((pass + 1)); } || { echo "FAIL: set -euo pipefail 下 ($res)"; fail=$((fail + 1)); }

# 失敗時は || exit 1 で止まる(set -e なし)
rm -f "$FAKE_COUNT"
res=$(FAKE_MODE=always503 bash -c 'source "$1"; value=$(bws_get_value some-id) || exit 1; echo "continued"' _ "$here/bws-retry.sh" 2>/dev/null)
[ -z "$res" ] && { echo "PASS: 失敗時に || exit 1 で止まる"; pass=$((pass + 1)); } || { echo "FAIL: 止まらなかった ($res)"; fail=$((fail + 1)); }

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
