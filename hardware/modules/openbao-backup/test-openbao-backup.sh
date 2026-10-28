#!/usr/bin/env bash
# openbao-backup.sh のオフラインテスト。偽の curl(OpenBao の API・B2 の S3 API・healthcheck)、偽の age、偽の date、
# 偽の logger を使うので、実機にも OpenBao にも B2 にも触れない。使い方: bash hardware/modules/openbao-backup/test-openbao-backup.sh
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/files/openbao-backup.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
checks=0
check() { checks=$((checks + 1)); if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected=$2 actual=$3)"; fails=$((fails + 1)); fi; }
rd() { command date "$@"; }   # 本物の date(テストの計算用)
REAL_DATE=$(command -v date)
export REAL_DATE

S3="$work/s3"; mkdir -p "$S3" "$work/bin"
export FAKE_DIR="$work" S3 FAKE_BUCKET=openbao-backup

# --- 偽の curl: Vault API(login / snapshot / revoke-self)、B2 の S3 API(HEAD / PUT)、healthcheck
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
method=GET; out=""; wfmt=""; is_head=false; dump_hdr=false; upload=""; use_cfg=false; url=""; allargs="$*"
while [ $# -gt 0 ]; do
  case "$1" in
    -K) use_cfg=true; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -w) wfmt="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    -D) dump_hdr=true; shift 2 ;;
    -I) is_head=true; method=HEAD; shift ;;
    --upload-file) upload="$2"; method=PUT; shift 2 ;;
    --max-time|--retry|--connect-timeout) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
cfg=""
if $use_cfg; then cfg=$(cat); fi
cfg_get() { printf '%s\n' "$cfg" | sed -nE "s/^$1 = \"(.*)\"\$/\1/p" | head -n 1; }
hdrs=$(printf '%s\n' "$cfg" | sed -nE 's/^header = "(.*)"$/\1/p')
hdr_val() { printf '%s\n' "$hdrs" | sed -nE "s/^$1: (.*)\$/\1/Ip" | head -n 1; }
u=$(cfg_get url); [ -n "$u" ] && url="$u"
if printf '%s\n' "$cfg" | grep -q '^data-binary = '; then method=POST; fi
echo "$method $url" >> "$FAKE_DIR/calls.log"
echo "ARGV $allargs" >> "$FAKE_DIR/argv.log"
if [ -n "${FAKE_DOWN_HOST:-}" ] && [[ "$url" == *"$FAKE_DOWN_HOST"* ]]; then
  [ -n "$wfmt" ] && printf '%b' "${wfmt//'%{http_code}'/000}"
  exit 7
fi

code=500; body=""; body_file=""; hout=""
case "$url" in
  */v1/auth/approle/login)
    data=$(cfg_get data-binary)
    if [ -n "${FAKE_LOGIN_FAIL:-}" ]; then code=403
    elif [[ "$data" == *'ROLE-ID-DO-NOT-LOG'* && "$data" == *'SECRET-ID-DO-NOT-LOG'* ]]; then
      code=200; body='{"auth":{"client_token":"hvs.FAKETOKEN","policies":["default","openbao-backup"]}}'
    else code=400; fi ;;
  */v1/sys/storage/raft/snapshot)
    if [ -n "${FAKE_SNAP_ALL:-}" ] || { [ -n "${FAKE_SNAP_DOWN_HOST:-}" ] && [[ "$url" == *"$FAKE_SNAP_DOWN_HOST"* ]]; }; then code=503
    elif [[ "$hdrs" != *"X-Vault-Token: hvs.FAKETOKEN"* ]]; then code=403
    elif [ -n "${FAKE_SNAP_BAD:-}" ]; then code=200; body='not a snapshot'
    else code=200; body_file="$FAKE_SNAPSHOT"; fi ;;
  */v1/auth/token/revoke-self)
    if [ -n "${FAKE_REVOKE_FAIL:-}" ]; then code=500
    elif [[ "$hdrs" != *"X-Vault-Token: hvs.FAKETOKEN"* ]]; then code=403
    else code=204; fi ;;
  *hc.example.invalid*) code=200 ;;
  *backblazeb2.com*)
    key="${url#*/${FAKE_BUCKET}/}"
    if ! printf '%s\n' "$cfg" | grep -q '^user = ' || ! printf '%s\n' "$cfg" | grep -q '^aws-sigv4 = '; then
      echo "unsigned request" >&2; exit 2
    fi
    if [ "$method" = DELETE ]; then code=204
    elif [ "$is_head" = true ]; then
      if [ -n "${FAKE_HEAD_ERR:-}" ] && [[ "$key" == *"$FAKE_HEAD_ERR"* ]]; then code=503
      elif [ -f "$S3/$key" ]; then code=200; hout="HTTP/1.1 200 OK\r\ncontent-length: $(wc -c < "$S3/$key" | tr -d ' ')\r\n\r\n"
      else code=404; hout="HTTP/1.1 404 Not Found\r\n\r\n"; fi
      $dump_hdr || hout=""
    elif [ "$method" = PUT ]; then
      mode=$(hdr_val 'x-amz-object-lock-mode'); until=$(hdr_val 'x-amz-object-lock-retain-until-date')
      sha=$(hdr_val 'x-amz-content-sha256'); md5=$(hdr_val 'Content-MD5')
      printf 'PUT %s mode=%s until=%s\n' "$key" "$mode" "$until" >> "$FAKE_DIR/put.log"
      if [ -z "$mode" ] || [ -z "$until" ]; then code=400
      elif [ "$sha" != "$(sha256sum "$upload" | awk '{print $1}')" ]; then code=400
      elif [ "$md5" != "$(openssl dgst -md5 -binary "$upload" | base64 | tr -d '\n')" ]; then code=400
      elif [ -n "${FAKE_PUT_FAIL:-}" ] && [[ "$key" == *"$FAKE_PUT_FAIL"* ]]; then code=500
      else
        mkdir -p "$(dirname "$S3/$key")"
        if [ -n "${FAKE_PUT_SHORT:-}" ] && [[ "$key" == *"$FAKE_PUT_SHORT"* ]]; then head -c 10 "$upload" > "$S3/$key"
        else cp "$upload" "$S3/$key"; fi
        code=200
      fi
    fi ;;
  *) code=404 ;;
esac

if [ -n "$hout" ]; then printf '%b' "$hout"; fi
if [ -n "$body_file" ]; then
  if [ -n "$out" ] && [ "$out" != /dev/null ]; then cp "$body_file" "$out"; fi
elif [ -n "$out" ]; then
  if [ "$out" != /dev/null ]; then printf '%s' "$body" > "$out"; fi
else
  printf '%s' "$body"
fi
[ -n "$wfmt" ] && printf '%b' "${wfmt//'%{http_code}'/$code}"
[ "$code" = 000 ] && exit 7
if [[ " $allargs " == *" -f"* ]] && [ "$code" -ge 400 ]; then exit 22; fi
exit 0
EOF

# --- 偽の age: 公開鍵を受け取り、age の書式の先頭行を付けて、標準入力を書く(-r が無ければ失敗)
cat > "$work/bin/age" <<'EOF'
#!/usr/bin/env bash
echo "age $*" >> "$FAKE_DIR/argv.log"
recipient=""; out=""
while [ $# -gt 0 ]; do case "$1" in -r) recipient="$2"; shift 2 ;; -o) out="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$recipient" ] || exit 1
[ -z "${FAKE_AGE_FAIL:-}" ] || exit 1
{ echo "age-encryption.org/v1"; echo "-> X25519 recipient=$recipient"; cat; } > "$out"
EOF

# --- 偽の date: 「今」(-u +%s)だけを、FAKE_NOW で差し替える。他の計算は本物の date
cat > "$work/bin/date" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FAKE_NOW:-}" ] && [ "$*" = "-u +%s" ]; then echo "$FAKE_NOW"; exit 0; fi
exec "$REAL_DATE" "$@"
EOF

# --- 偽の logger: 記録だけ(ログに残るかを、テストで確かめる)
cat > "$work/bin/logger" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DIR/logger.log"
EOF
chmod +x "$work/bin/"*

export PATH="$work/bin:$PATH"
export ENV_FILE=/nonexistent
export LOCK_FILE="$work/lock"
export SNAPSHOT_BASE="$work/ram" REQUIRE_TMPFS=0
export TEXTFILE_DIR="$work/textfile"
export B2_ENDPOINT=https://s3.us-west-004.backblazeb2.com B2_REGION=us-west-004 B2_BUCKET=openbao-backup
export B2_ACCESS_KEY_ID=KEYID-TEST B2_SECRET_ACCESS_KEY=B2SECRET-DO-NOT-LOG
export AGE_RECIPIENT="age1$(printf 'q%.0s' {1..58})"
export BAO_ENDPOINTS="https://bao-02.kigawa.net:8200 https://bao-03.kigawa.net:8200"
export BAO_ROLE_ID_FILE="$work/role_id" BAO_SECRET_ID_FILE="$work/secret_id"
printf 'ROLE-ID-DO-NOT-LOG\n' > "$BAO_ROLE_ID_FILE"
printf 'SECRET-ID-DO-NOT-LOG\n' > "$BAO_SECRET_ID_FILE"
export HEALTHCHECK_URL=https://hc.example.invalid/ping/HC-DO-NOT-LOG

# 偽のスナップショット(gzip の tar: meta.json と state.bin)
fx="$work/fixture"; mkdir -p "$fx"
echo '{"version":"fake"}' > "$fx/meta.json"; head -c 8192 /dev/urandom > "$fx/state.bin"
tar -C "$fx" -czf "$work/snapshot.tar.gz" meta.json state.bin
export FAKE_SNAPSHOT="$work/snapshot.tar.gz"

reset() {
  rm -rf "$S3" "$TEXTFILE_DIR" "$SNAPSHOT_BASE" "$work/calls.log" "$work/argv.log" "$work/logger.log" "$work/put.log" "$work/out.txt"
  mkdir -p "$S3"
  unset FAKE_LOGIN_FAIL FAKE_SNAP_ALL FAKE_SNAP_DOWN_HOST FAKE_SNAP_BAD FAKE_AGE_FAIL FAKE_PUT_FAIL FAKE_PUT_SHORT \
        FAKE_HEAD_ERR FAKE_REVOKE_FAIL FAKE_DOWN_HOST
  export OBJECT_LOCK_MODE=GOVERNANCE
  export HEALTHCHECK_URL=https://hc.example.invalid/ping/HC-DO-NOT-LOG
  export BAO_ENDPOINTS="https://bao-02.kigawa.net:8200 https://bao-03.kigawa.net:8200"
  export BAO_ROLE_ID_FILE="$work/role_id" BAO_SECRET_ID_FILE="$work/secret_id"
}
# 指定の時刻に 1 回実行する。終了コードを返す(出力は $work/out.txt)
run_at() {
  local when="$1"; shift
  FAKE_NOW=$(rd -u -d "$when" +%s); export FAKE_NOW
  : > "$work/put.log"
  bash "$script" "$@" > "$work/out.txt" 2>&1
  echo $?
  unset FAKE_NOW
}
# 直近の実行でアップロードした世代(本体のオブジェクト。.sha256 は除く)
put_keys() { awk '$1 == "PUT" {print $2}' "$work/put.log" 2>/dev/null | grep -v '\.sha256$' || true; }
tiers_of_last_run() { put_keys | awk -F/ '{print $1}' | tr '\n' ' ' | sed 's/ $//'; }
until_of() { awk -v k="$1" '$1 == "PUT" && $2 == k {sub("until=", "", $4); print $4}' "$work/put.log" | head -n 1; }
count_objects() { find "$S3/$1" -type f ! -name "*.sha256" 2>/dev/null | wc -l | tr -d " "; }
metric() { grep -E "^$1 " "$TEXTFILE_DIR/openbao_backup.prom" 2>/dev/null | awk '{print $2}'; }
tier_metric() { grep -E "^openbao_backup_tier_last_success_timestamp_seconds\{tier=\"$1\"\} " "$TEXTFILE_DIR/openbao_backup.prom" 2>/dev/null | awk '{print $2}'; }
plaintext_left() { find "$SNAPSHOT_BASE" -mindepth 1 2>/dev/null | wc -l | tr -d ' '; }

exp_until() { rd -u -d "@$(( $1 + $2 * 86400 ))" +%Y-%m-%dT%H:%M:%SZ; }   # 基準の epoch, 日数

T_WED_0600=2026-10-28T06:00:00Z   # 水曜、週の途中、月の途中
T_WED_1200=2026-10-28T12:00:00Z
T_THU_0000=2026-10-29T00:00:00Z   # 日付が変わる
T_SUN_0600=2026-11-01T06:00:00Z   # 月初(日曜。W44 のまま)
T_MON_0000=2026-11-02T00:00:00Z   # 月曜(週が変わる、W45)
T_MON_0600=2026-11-02T06:00:00Z
T_TUE_0600=2026-11-03T06:00:00Z

echo "== 1. 世代の選択(tier selection)"
reset
check "fresh bucket, WED 06:00: exit 0" 0 "$(run_at $T_WED_0600)"
check "fresh bucket: writes 6h daily weekly monthly" "6h daily weekly monthly" "$(tiers_of_last_run)"
check "WED 12:00 (same day, week, month): only 6h" 0 "$(run_at $T_WED_1200)"
check "same day/week/month: only 6h is written" "6h" "$(tiers_of_last_run)"
check "THU 00:00 (day boundary): 6h + daily" 0 "$(run_at $T_THU_0000)"
check "day boundary: 6h daily" "6h daily" "$(tiers_of_last_run)"
check "SUN 11-01 06:00 (first of month): 6h daily monthly (no weekly, W44 exists)" 0 "$(run_at $T_SUN_0600)"
check "first of month: 6h daily monthly" "6h daily monthly" "$(tiers_of_last_run)"
check "MON 11-02 00:00 (week boundary): 6h daily weekly" 0 "$(run_at $T_MON_0000)"
check "Monday: 6h daily weekly" "6h daily weekly" "$(tiers_of_last_run)"
check "Monday 06:00 again: only 6h" 0 "$(run_at $T_MON_0600)"
check "same period again: only 6h" "6h" "$(tiers_of_last_run)"
check "6h objects: one per run (6 runs)" 6 "$(count_objects 6h)"
check "daily objects: one per day (4 days)" 4 "$(count_objects daily)"
check "weekly objects: one per week (2 weeks)" 2 "$(count_objects weekly)"
check "monthly objects: one per month (2 months)" 2 "$(count_objects monthly)"
check "daily key is the UTC date" yes "$([ -f "$S3/daily/2026-10-29.raft.snap.age" ] && echo yes || echo no)"
check "weekly key is the ISO week (W45 on 11-02)" yes "$([ -f "$S3/weekly/2026-W45.raft.snap.age" ] && echo yes || echo no)"
check "monthly key is the UTC month" yes "$([ -f "$S3/monthly/2026-11.raft.snap.age" ] && echo yes || echo no)"

echo "== 2. 期間の最初の実行で書く(火曜の実行で、週と月を補う)"
reset
check "fresh bucket, TUE 11-03 06:00: exit 0" 0 "$(run_at $T_TUE_0600)"
check "no Monday run: the first run of the week writes weekly" "6h daily weekly monthly" "$(tiers_of_last_run)"

echo "== 3. Object Lock の保持期間(UTC で計算)"
reset
run_at $T_WED_0600 >/dev/null
base=$(rd -u -d "$T_WED_0600" +%s)
k6h=$(put_keys | grep '^6h/')
check "6h: retain until now + 7 days" "$(exp_until "$base" 7)" "$(until_of "$k6h")"
check "daily: retain until now + 30 days" "$(exp_until "$base" 30)" "$(until_of daily/2026-10-28.raft.snap.age)"
check "weekly: retain until now + 84 days" "$(exp_until "$base" 84)" "$(until_of weekly/2026-W44.raft.snap.age)"
check "monthly: retain until now + 365 days" "$(exp_until "$base" 365)" "$(until_of monthly/2026-10.raft.snap.age)"
check "every PUT carries a lock mode (GOVERNANCE)" 0 "$(awk '$1 == "PUT" && $3 != "mode=GOVERNANCE"' "$work/put.log" | wc -l | tr -d ' ')"
check "every PUT has a retain-until date" 0 "$(awk '$1 == "PUT" && $4 == "until="' "$work/put.log" | wc -l | tr -d ' ')"
reset; export OBJECT_LOCK_MODE=COMPLIANCE
run_at $T_WED_0600 >/dev/null
check "OBJECT_LOCK_MODE=COMPLIANCE is sent as the mode" 0 "$(awk '$1 == "PUT" && $3 != "mode=COMPLIANCE"' "$work/put.log" | wc -l | tr -d ' ')"
reset

echo "== 4. 冪等: 期間の世代は一度だけ書かれる。sha256 の側ファイルも同じ"
reset
run_at $T_WED_0600 >/dev/null
check "sha256 side file written next to the 6h object" yes "$([ -f "$S3/$k6h.sha256" ] && echo yes || echo no)"
check "side file holds the sha256 of the ciphertext" yes "$(awk '{print $1}' "$S3/$k6h.sha256" | grep -qE '^[0-9a-f]{64}$' && echo yes || echo no)"
run_at $T_WED_0600 >/dev/null
check "rerun at the same time: daily is not written again" 0 "$(put_keys | grep -c '^daily/')"
check "rerun: only the new 6h object" "6h" "$(tiers_of_last_run)"
check "rerun: daily object count is still 1" 1 "$(count_objects daily)"

echo "== 5. --reason は adhoc/<reason>/ に、30 日の保持で書く"
reset
check "--reason pre-upgrade: exit 0" 0 "$(run_at $T_WED_0600 --reason pre-upgrade)"
check "--reason: only adhoc is written" "adhoc" "$(tiers_of_last_run)"
check "--reason: key is under adhoc/pre-upgrade/" yes "$(put_keys | grep -q '^adhoc/pre-upgrade/' && echo yes || echo no)"
check "--reason: retain until now + 30 days" "$(exp_until "$(rd -u -d "$T_WED_0600" +%s)" 30)" "$(until_of "$(put_keys)")"
check "--reason: 6h is not written" 0 "$(count_objects 6h)"
check "--reason: invalid value (path traversal) exits 2" 2 "$(run_at $T_WED_0600 --reason ../x)"
check "--reason: invalid value uploads nothing" 0 "$(wc -l < "$work/put.log" | tr -d ' ')"
check "--reason without value exits 2" 2 "$(run_at $T_WED_0600 --reason)"
check "unknown argument exits 2" 2 "$(run_at $T_WED_0600 --bogus)"

echo "== 6. 成功時の処理: メトリクス、ping、平文が残らない"
reset
check "success: exit 0" 0 "$(run_at $T_WED_0600)"
check "success: last_run_success=1" 1 "$(metric openbao_backup_last_run_success)"
check "success: last_success_timestamp present" yes "$([ -n "$(metric openbao_backup_last_success_timestamp_seconds)" ] && echo yes || echo no)"
check "success: size_bytes > 0" yes "$([ "$(metric openbao_backup_size_bytes)" -gt 0 ] && echo yes || echo no)"
check "success: duration present" yes "$([ -n "$(metric openbao_backup_duration_seconds)" ] && echo yes || echo no)"
check "success: 6h tier timestamp present" yes "$([ -n "$(tier_metric 6h)" ] && echo yes || echo no)"
check "success: monthly tier timestamp present" yes "$([ -n "$(tier_metric monthly)" ] && echo yes || echo no)"
check "success: adhoc tier not set" "" "$(tier_metric adhoc)"
check "success: no textfile tmp left" 0 "$(find "$TEXTFILE_DIR" -name '.*' | wc -l | tr -d ' ')"
check "success: ping sent to the success URL" yes "$(grep -q 'GET https://hc.example.invalid/ping/HC-DO-NOT-LOG$' "$work/calls.log" && echo yes || echo no)"
check "success: ping is not sent to /fail" no "$(grep -q '/fail$' "$work/calls.log" && echo yes || echo no)"
check "success: no plaintext snapshot left (RAM dir empty)" 0 "$(plaintext_left)"
check "success: uploaded objects start with the age header" yes "$(head -n 1 "$S3/$k6h" | grep -qx 'age-encryption.org/v1' && echo yes || echo no)"
check "success: the recipient is the public key" yes "$(grep -q "recipient=$AGE_RECIPIENT" "$S3/$k6h" && echo yes || echo no)"
check "success: revoke-self called" yes "$(grep -q 'POST https://bao-02.kigawa.net:8200/v1/auth/token/revoke-self' "$work/calls.log" && echo yes || echo no)"

echo "== 7. 秘密は、出力・ログ・textfile・コマンドラインに出ない"
reset
run_at $T_WED_0600 >/dev/null
for secret in ROLE-ID-DO-NOT-LOG SECRET-ID-DO-NOT-LOG hvs.FAKETOKEN B2SECRET-DO-NOT-LOG HC-DO-NOT-LOG; do
  check "secret $secret not in output/log/textfile/argv" "no" "$(grep -rq -- "$secret" "$work/out.txt" "$work/logger.log" "$TEXTFILE_DIR" "$work/argv.log" 2>/dev/null && echo yes || echo no)"
done
check "no B2 request carries an unsigned request" "no" "$(grep -q 'unsigned' "$work/out.txt" && echo yes || echo no)"
reset
run_at $T_WED_0600 >/dev/null; export FAKE_PUT_FAIL=6h/
run_at $T_WED_0600 >/dev/null
check "secrets absent from the failure path too" "no" "$(grep -rq -- 'SECRET-ID-DO-NOT-LOG\|hvs.FAKETOKEN\|B2SECRET-DO-NOT-LOG\|HC-DO-NOT-LOG' "$work/out.txt" "$work/logger.log" "$TEXTFILE_DIR" "$work/argv.log" 2>/dev/null && echo yes || echo no)"
reset

echo "== 8. 失敗: 各段階で、失敗のメトリクスと /fail の ping、平文を残さない"
fail_check() { # 名前, 期待する終了コード。失敗の観点は、関数の中で確かめる
  local name="$1" rc="$2" got
  got=$(run_at $T_WED_0600)
  check "$name: exit $rc" "$rc" "$got"
  check "$name: last_run_success=0" 0 "$(metric openbao_backup_last_run_success)"
  check "$name: ping /fail sent" yes "$(grep -q '/fail$' "$work/calls.log" && echo yes || echo no)"
  check "$name: no plaintext left" 0 "$(plaintext_left)"
}
reset; export FAKE_LOGIN_FAIL=1; fail_check "login fails everywhere" 1; unset FAKE_LOGIN_FAIL
reset; export FAKE_SNAP_ALL=1; fail_check "snapshot fails everywhere" 1; unset FAKE_SNAP_ALL
reset; export FAKE_SNAP_BAD=1; fail_check "snapshot is not a snapshot" 1; unset FAKE_SNAP_BAD
reset; export FAKE_AGE_FAIL=1; fail_check "age encryption fails" 1; unset FAKE_AGE_FAIL
reset; export FAKE_PUT_FAIL=6h/; fail_check "upload of the 6h object fails" 1; unset FAKE_PUT_FAIL
reset; export FAKE_PUT_SHORT=6h/; fail_check "uploaded size differs from local" 1; unset FAKE_PUT_SHORT
reset; export FAKE_HEAD_ERR=daily/
check "HEAD error on a tier marker: exit 1" 1 "$(run_at $T_WED_0600)"
check "HEAD error: nothing uploaded at all" 0 "$(wc -l < "$work/put.log" | tr -d ' ')"
check "HEAD error: /fail ping sent" yes "$(grep -q '/fail$' "$work/calls.log" && echo yes || echo no)"
unset FAKE_HEAD_ERR
reset; export BAO_ROLE_ID_FILE="$work/no-such-file"
check "missing role_id file: exit 1" 1 "$(run_at $T_WED_0600)"
check "missing role_id file: nothing uploaded" 0 "$(wc -l < "$work/put.log" 2>/dev/null | tr -d ' ')"
export BAO_ROLE_ID_FILE="$work/role_id"
reset
rc=$(AGE_RECIPIENT= run_at $T_WED_0600)
check "missing AGE_RECIPIENT: exit 1" 1 "$rc"
check "missing AGE_RECIPIENT: nothing uploaded" 0 "$(wc -l < "$work/put.log" | tr -d ' ')"
check "invalid AGE_RECIPIENT (not age1 + 58 chars): exit 1" 1 "$(AGE_RECIPIENT=age1short run_at $T_WED_0600)"
check "B2_REGION mismatching the endpoint: exit 1" 1 "$(B2_REGION=eu-central-003 run_at $T_WED_0600)"
check "invalid B2_ENDPOINT: exit 1" 1 "$(B2_ENDPOINT=http://example.invalid run_at $T_WED_0600)"
check "invalid OBJECT_LOCK_MODE: exit 1" 1 "$(OBJECT_LOCK_MODE=NONE run_at $T_WED_0600)"
check "config errors: nothing uploaded" 0 "$(wc -l < "$work/put.log" | tr -d ' ')"
reset
echo "== 8b. 失敗の時刻は、前回の成功を引き継ぐ(アラートの基準)"
reset
run_at $T_WED_0600 >/dev/null
first_ok=$(metric openbao_backup_last_success_timestamp_seconds)
first_tier=$(tier_metric 6h)
export FAKE_LOGIN_FAIL=1
run_at $T_WED_1200 >/dev/null
check "failure after a success: last_success_timestamp carried over" "$first_ok" "$(metric openbao_backup_last_success_timestamp_seconds)"
check "failure: 6h tier timestamp carried over" "$first_tier" "$(tier_metric 6h)"
unset FAKE_LOGIN_FAIL
reset
echo "== 8c. 外部の死活監視(HEALTHCHECK_URL)が空なら、何も送らない"
reset; export HEALTHCHECK_URL=
check "empty HEALTHCHECK_URL: success exit 0" 0 "$(run_at $T_WED_0600)"
check "empty HEALTHCHECK_URL: no request to any healthcheck" 0 "$(grep -c 'hc.example' "$work/calls.log" 2>/dev/null || true)"
reset; export FAKE_LOGIN_FAIL=1; export HEALTHCHECK_URL=
check "empty HEALTHCHECK_URL: failure still exit 1" 1 "$(run_at $T_WED_0600)"
unset FAKE_LOGIN_FAIL
reset

echo "== 9. エンドポイントの切り替え"
reset; export FAKE_DOWN_HOST=bao-02
check "bao-02 down: exit 0 (failover to bao-03)" 0 "$(run_at $T_WED_0600)"
check "bao-02 down: login on bao-03" yes "$(grep -q 'POST https://bao-03.kigawa.net:8200/v1/auth/approle/login' "$work/calls.log" && echo yes || echo no)"
check "bao-02 down: snapshot taken from bao-03" yes "$(grep -q 'GET https://bao-03.kigawa.net:8200/v1/sys/storage/raft/snapshot' "$work/calls.log" && echo yes || echo no)"
check "bao-02 down: revoke on bao-03" yes "$(grep -q 'POST https://bao-03.kigawa.net:8200/v1/auth/token/revoke-self' "$work/calls.log" && echo yes || echo no)"
reset; export FAKE_SNAP_DOWN_HOST=bao-02
check "snapshot refused by bao-02 (standby): exit 0" 0 "$(run_at $T_WED_0600)"
check "snapshot: tried bao-02 first, then bao-03" "yes yes" "$(echo "$(grep -q 'GET https://bao-02.kigawa.net:8200/v1/sys/storage/raft/snapshot' "$work/calls.log" && echo yes) $(grep -q 'GET https://bao-03.kigawa.net:8200/v1/sys/storage/raft/snapshot' "$work/calls.log" && echo yes)")"
reset; export FAKE_REVOKE_FAIL=1
check "revoke failure does not fail the backup: exit 0" 0 "$(run_at $T_WED_0600)"
check "revoke failure: warning logged" yes "$(grep -q 'WARNING: token revoke failed' "$work/out.txt" && echo yes || echo no)"
reset

echo "== 10. 同時実行は、後のものがスキップされる(flock)"
reset
( flock 9; sleep 3 ) 9>"$LOCK_FILE" &
sleep 0.5
check "concurrent run: skipped with exit 0" 0 "$(run_at $T_WED_0600)"
check "concurrent run: nothing uploaded" 0 "$(wc -l < "$work/put.log" | tr -d ' ')"
wait

echo "== 11. 削除は一度もしない(保持は Object Lock と Lifecycle に任せる)"
reset
run_at $T_WED_0600 >/dev/null; run_at $T_THU_0000 >/dev/null; run_at $T_THU_0000 --reason x >/dev/null 2>&1
check "no DELETE request was ever sent" 0 "$(grep -c '^DELETE ' "$work/calls.log" 2>/dev/null || true)"
check "no object was removed (6h objects accumulate)" 2 "$(count_objects 6h)"

echo "== 12. 平文のスナップショットは、RAM の作業ディレクトリにだけ置かれ、残らない"
reset
run_at $T_WED_0600 >/dev/null
check "RAM dir is 0700 after a run" 700 "$(stat -c %a "$SNAPSHOT_BASE" 2>/dev/null)"
check "no run directory left" 0 "$(plaintext_left)"

if [ "$fails" -eq 0 ]; then echo "all $checks checks passed"; else echo "$fails of $checks check(s) failed"; exit 1; fi
