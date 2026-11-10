#!/usr/bin/env bash
# lib/secret-get.sh と scripts/migrate-secrets-to-openbao.sh のテスト。
# 偽の bws / bao を使うので Bitwarden / OpenBao には接続しない。
#   bash lib/test-secret-get.sh
set -u
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/store"

# 偽 bws: 値は SECRET-<uuid>
cat > "$tmp/bin/bws" <<'EOF'
#!/usr/bin/env bash
echo "{\"value\":\"SECRET-$3\"}"
EOF

# 偽 bao: $FAKE_STORE/<path の / を _ に>/<field> にファイルで保存
cat > "$tmp/bin/bao" <<'EOF'
#!/usr/bin/env bash
S="${FAKE_STORE:?FAKE_STORE not set}"
[ "$1" = kv ] || exit 1
shift; sub=$1; shift
case $sub in
  get)
    if [ "${1#-field=}" != "$1" ]; then
      f=${1#-field=}; d=$(printf '%s' "$2" | tr / _)
      [ -f "$S/$d/$f" ] && cat "$S/$d/$f" || exit 2
    else
      d=$(printf '%s' "$1" | tr / _); [ -d "$S/$d" ] || exit 2
    fi ;;
  put|patch)
    d=$(printf '%s' "$1" | tr / _); kv=$2
    mkdir -p "$S/$d"; cat > "$S/$d/${kv%%=*}"; echo "$sub" >> "$S/log" ;;
esac
EOF
chmod +x "$tmp/bin/bws" "$tmp/bin/bao"
export PATH="$tmp/bin:$PATH" FAKE_STORE="$tmp/store"

fail=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi
}
csv="$repo/scripts/secrets-to-migrate.csv"
cf1=592c8dfd-1622-47cb-abb9-b4f00103c2a3
cf2=2ca12501-85e3-4b5b-a4e7-b4a201031365

# migrate: dry-run は書き込まず、値を出力しない
out=$("$repo/scripts/migrate-secrets-to-openbao.sh" --dry-run "$csv" 2>&1); rc=$?
check "dry-run rc" 0 "$rc"
check "dry-run no writes" "" "$(ls "$tmp/store")"
check "dry-run no leak" 0 "$(printf '%s' "$out" | grep -c SECRET-)"

# execute: 7 件中、同一パスの重複 1 件はスキップ
out=$("$repo/scripts/migrate-secrets-to-openbao.sh" --execute "$csv" 2>&1); rc=$?
check "execute rc" 0 "$rc"
check "execute no leak" 0 "$(printf '%s' "$out" | grep -c SECRET-)"
check "execute summary" "summary: execute=6 skipped=1 failed=0" "$(printf '%s' "$out" | tail -1)"
check "value stored" "SECRET-$cf1" "$(cat "$tmp/store/secret_infra_hardware_cloudflare-api/token")"

# 再実行は全スキップ(冪等)
out=$("$repo/scripts/migrate-secrets-to-openbao.sh" --execute "$csv" 2>&1)
check "idempotent" "summary: execute=0 skipped=7 failed=0" "$(printf '%s' "$out" | tail -1)"

# secret_get_value
get() {
  SECRET_BACKEND=$1 bash -c "
    export PATH='$PATH'
    export FAKE_STORE='$FAKE_STORE'
    source '$repo/lib/secret-get.sh'
    secret_get_value $2
  " 2>/dev/null
}
check "backend bws" "SECRET-$cf1" "$(get bws $cf1)"
check "backend bao" "SECRET-$cf1" "$(get bao $cf1)"
check "backend bao-first (bao hit)" "SECRET-$cf1" "$(get bao-first $cf1)"
unmapped=00000000-0000-0000-0000-000000000000
check "backend bao-first fallback" "SECRET-$unmapped" "$(get bao-first $unmapped)"
get bao "$unmapped" >/dev/null; check "backend bao unmapped fails" 1 "$(bash -c "export PATH='$PATH'; export FAKE_STORE='$FAKE_STORE'; SECRET_BACKEND=bao bash -c \"export PATH='$PATH'; export FAKE_STORE='$FAKE_STORE'; source '$repo/lib/secret-get.sh'; secret_get_value $unmapped\" >/dev/null 2>&1; echo \$?" 2>&1)"
check "unknown backend fails" 1 "$(bash -c "export PATH='$PATH'; export FAKE_STORE='$FAKE_STORE'; SECRET_BACKEND=zzz bash -c \"export PATH='$PATH'; export FAKE_STORE='$FAKE_STORE'; source '$repo/lib/secret-get.sh'; secret_get_value $cf2\" >/dev/null 2>&1; echo \$?" 2>&1)"

exit $fail
