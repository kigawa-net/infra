#!/bin/bash
# overlay-allow-source.sh のオフラインテスト。偽の iptables(ルールをファイルに持つ)を使い、本物のファイアウォールには触らない。
# 使い方: bash hardware/modules/overlay-allow-source/test-overlay-allow-source.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
RULES="$T/rules"
: > "$RULES"

cat > "$T/bin/iptables" <<'FAKE'
#!/bin/bash
# 対応: -C INPUT <spec...> / -I INPUT 1 <spec...> / -D INPUT <spec...> / -S INPUT
rules="$FAKE_RULES"
op=$1; shift
case "$op" in
  -S) shift; cat "$rules" ;;
  -C) shift; grep -qxF -- "$*" "$rules" ;;
  -I) shift; shift; { echo "$*"; cat "$rules"; } > "$rules.new"; mv "$rules.new" "$rules" ;;
  -D) shift; grep -vxF -- "$*" "$rules" > "$rules.new" || true; mv "$rules.new" "$rules" ;;
  *) echo "fake iptables: unsupported $op" >&2; exit 2 ;;
esac
FAKE
chmod +x "$T/bin/iptables"
export FAKE_RULES="$RULES"
export PATH="$T/bin:$PATH"
export OA_CONF="$T/etc/sources.conf" OA_HELPER="$T/sbin/overlay-allow-source" OA_UNIT_DIR="$T/systemd" OA_TESTING=1

fail() { echo "FAIL: $*"; echo "--- rules:"; cat "$RULES"; exit 1; }

# 1) 1 つの送信元を入れる
OA_SOURCES="10.250.0.240" bash "$here/files/overlay-allow-source.sh" >/dev/null
grep -qxF -- "-s 10.250.0.240 -p tcp -j ACCEPT" "$RULES" || fail "許可が入っていない"
[ -x "$OA_HELPER" ] || fail "helper が実行できない"
grep -q "After=network-online.target easytier.service" "$OA_UNIT_DIR/overlay-allow-source.service" || fail "unit が easytier の後になっていない"
grep -q "PartOf=easytier.service" "$OA_UNIT_DIR/overlay-allow-source.service" || fail "unit が easytier に連動していない"

# 2) 2 回目(冪等): 重複しない
OA_SOURCES="10.250.0.240" bash "$here/files/overlay-allow-source.sh" >/dev/null
[ "$(grep -cxF -- "-s 10.250.0.240 -p tcp -j ACCEPT" "$RULES")" = 1 ] || fail "重複して入った"

# 3) 送信元を変える: 古いものが消え、新しいものが先頭に入る
OA_SOURCES="10.250.0.241" bash "$here/files/overlay-allow-source.sh" >/dev/null
grep -qxF -- "-s 10.250.0.240 -p tcp -j ACCEPT" "$RULES" && fail "外した送信元が残っている"
[ "$(head -1 "$RULES")" = "-s 10.250.0.241 -p tcp -j ACCEPT" ] || fail "新しい許可が先頭にない"

# 4) overlay-firewall が先頭に入れ直した(許可が後ろに回った)あと、helper up で先頭に戻る
echo "-s 10.250.0.0/24 -j EASYTIER-OVERLAY" | cat - "$RULES" > "$RULES.x"; mv "$RULES.x" "$RULES"
"$OA_HELPER" down
"$OA_HELPER" up
[ "$(head -1 "$RULES")" = "-s 10.250.0.241 -p tcp -j ACCEPT" ] || fail "再起動後に許可が先頭に戻らない"

# 5) down で消える(overlay-firewall のチェインへの飛ばしは残る)
"$OA_HELPER" down
grep -qxF -- "-s 10.250.0.241 -p tcp -j ACCEPT" "$RULES" && fail "down で消えない"
grep -qxF -- "-s 10.250.0.0/24 -j EASYTIER-OVERLAY" "$RULES" || fail "他のルールを消した"

# 6) OA_SOURCES が無いとエラー
if env -u OA_SOURCES bash "$here/files/overlay-allow-source.sh" >/dev/null 2>&1; then fail "OA_SOURCES なしで成功した"; fi

echo "OK: overlay-allow-source のテストが、すべて通りました"
