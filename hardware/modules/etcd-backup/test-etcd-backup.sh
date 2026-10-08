#!/usr/bin/env bash
# etcd-backup.sh のオフラインテスト。偽の crictl / age / curl(S3 の模擬)/ df を使うので、
# 実機にも R2 にも触れない。使い方: bash hardware/modules/etcd-backup/test-etcd-backup.sh
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/files/etcd-backup.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected=$2 actual=$3)"; fails=$((fails + 1)); fi; }

S3="$work/s3"; mkdir -p "$S3" "$work/bin"

# --- 偽の crictl: etcd コンテナのふり
cat > "$work/bin/crictl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "ps --name ^etcd\$ -q") [ -z "${FAKE_NO_ETCD:-}" ] && echo abc123 ;;
  *"endpoint status"*) echo "[{\"Status\":{\"dbSize\":${FAKE_DB_BYTES:-1000000}}}]" ;;
  *"snapshot save"*) path="${@: -1}"; [ -n "${FAKE_SNAP_FAIL:-}" ] && exit 1; head -c "${FAKE_DB_BYTES:-1000000}" /dev/zero > "$path" ;;
  *"etcdutl"*) echo "etcdutl is not in the kubeadm etcd image" >&2; exit 127 ;;
  *"snapshot status"*) [ -n "${FAKE_STATUS_SLEEP:-}" ] && sleep "$FAKE_STATUS_SLEEP"; [ -n "${FAKE_STATUS_FAIL:-}" ] && exit 1; echo '{"hash":123,"revision":42,"totalKey":100,"totalSize":1000}' ;;
esac
EOF
# --- 偽の age: 暗号化のふり(受け取った公開鍵を先頭行に書く)。-r が空なら失敗
cat > "$work/bin/age" <<'EOF'
#!/usr/bin/env bash
recipient=""; out=""
while [ $# -gt 0 ]; do case "$1" in -r) recipient="$2"; shift 2 ;; -o) out="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$recipient" ] || exit 1
{ echo "AGE-FAKE recipient=$recipient"; cat; } > "$out"
EOF
# --- 偽の curl: S3(R2)を、ディレクトリで模擬する
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
method=GET; file=""; out=""; wfmt=""; head=false; list=false; user=""; sigv4=""
args=("$@"); url="${args[$((${#args[@]} - 1))]}"
i=0
while [ $i -lt ${#args[@]} ]; do
  a="${args[$i]}"
  case "$a" in
    -X) method="${args[$((i + 1))]}"; i=$((i + 1)) ;;
    --upload-file) file="${args[$((i + 1))]}"; method=PUT; i=$((i + 1)) ;;
    -o) out="${args[$((i + 1))]}"; i=$((i + 1)) ;;
    -w) wfmt="${args[$((i + 1))]}"; i=$((i + 1)) ;;
    -I) head=true ;;
    -G) list=true ;;
    --user) user="${args[$((i + 1))]}"; i=$((i + 1)) ;;
    --aws-sigv4) sigv4="${args[$((i + 1))]}"; i=$((i + 1)) ;;
    --data-urlencode)
      if [[ "${args[$((i + 1))]}" == prefix=* ]]; then prefix="${args[$((i + 1))]#prefix=}"; fi
      if [[ "${args[$((i + 1))]}" == continuation-token=* ]]; then token="${args[$((i + 1))]#continuation-token=}"; fi
      i=$((i + 1)) ;;
  esac
  i=$((i + 1))
done
echo "$method $url" >> "$FAKE_DIR/curl.log"
[ -n "$sigv4" ] && [ -n "$user" ] || { echo "unsigned request" >&2; exit 2; }
key="${url#*://*/}"; key="${key#*/}"     # bucket を除いた key
if $head; then
  [ -f "$S3/$key" ] || exit 0
  echo "HTTP/2 200"; echo "content-length: $(wc -c < "$S3/$key" | tr -d ' ')"; exit 0
fi
if $list; then
  # ページネーション: FAKE_PAGE_SIZE 個ずつ返す。token は、次の開始位置(数)
  all=$(cd "$S3" && find . -type f | sed 's#^\./##' | grep "^${prefix}" | sort)
  total=$(printf '%s\n' "$all" | grep -c . || true)
  start="${token:-0}"; size="${FAKE_PAGE_SIZE:-1000000}"; end=$((start + size))
  trunc=false; [ "$end" -lt "$total" ] && trunc=true
  [ -n "${FAKE_TRUNCATED:-}" ] && trunc="$FAKE_TRUNCATED"        # トークンの無い、壊れた「不完全」な一覧を模擬
  echo "<ListBucketResult><IsTruncated>${trunc}</IsTruncated>"
  [ "$trunc" = true ] && [ -z "${FAKE_TRUNCATED:-}" ] && echo "<NextContinuationToken>${end}</NextContinuationToken>"
  printf '%s\n' "$all" | sed -n "$((start + 1)),${end}p" | while read -r k; do [ -n "$k" ] && echo "<Contents><Key>$k</Key></Contents>"; done
  echo "</ListBucketResult>"; exit 0
fi
case "$method" in
  PUT)
    if [ -n "${FAKE_PUT_FAIL:-}" ] && [[ "$key" == *"${FAKE_PUT_FAIL}"* ]]; then code=500
    else mkdir -p "$S3/$(dirname "$key")"; cp "$file" "$S3/$key"; code=200; fi ;;
  DELETE) rm -f "$S3/$key"; code=204 ;;
esac
[ -n "$wfmt" ] && printf '%s' "$code"
exit 0
EOF
cat > "$work/bin/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem 1048576-blocks Used Available Capacity Mounted"
echo "/dev/x 100000 1000 ${FAKE_FREE_MB:-50000} 2% /"
EOF
cat > "$work/bin/logger" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DIR/logger.log"
EOF
chmod +x "$work/bin/"*

export FAKE_DIR="$work" S3
export PATH="$work/bin:$PATH"
export ENV_FILE=/nonexistent
export R2_ENDPOINT=https://r2.example.invalid R2_BUCKET=etcd-backup R2_ACCESS_KEY_ID=AKIDTEST R2_SECRET_ACCESS_KEY=SECRET-DO-NOT-LOG
export AGE_RECIPIENT=age1testrecipient NODE_NAME=k8s2 RETENTION_DAYS=14 MIN_KEEP=5
export SNAPSHOT_PATH="$work/snap.db" PKI_DIR="$work/kube" TEXTFILE_DIR="$work/textfile" LOCK_FILE="$work/lock" TMPDIR="$work"
mkdir -p "$PKI_DIR/pki" && echo cert > "$PKI_DIR/pki/ca.crt" && echo conf > "$PKI_DIR/admin.conf"

reset() {
  rm -rf "$S3" "$TEXTFILE_DIR" "$work/curl.log" "$work/logger.log" "$work/out.txt" "$SNAPSHOT_PATH"; mkdir -p "$S3"
  unset FAKE_NO_ETCD FAKE_SNAP_FAIL FAKE_STATUS_FAIL FAKE_STATUS_SLEEP FAKE_PUT_FAIL FAKE_TRUNCATED FAKE_PAGE_SIZE FAKE_FREE_MB FAKE_DB_BYTES
}
run() { bash "$script" > "$work/out.txt" 2>&1; echo $?; }
add_gen() { # ts [node]
  local node="${2:-k8s2}"; mkdir -p "$S3/$node/$1"
  for f in etcd-snapshot.db.gz.age pki.tar.gz.age snapshot-status.json.age; do echo x > "$S3/$node/$1/$f"; done
}
# 世代の数 = スナップショットのファイルがあるディレクトリの数(偽の S3 は、削除でファイルだけを消す)
gens() { find "$S3/k8s2" -mindepth 2 -type f -name 'etcd-snapshot.db.gz.age' 2>/dev/null | wc -l | tr -d ' '; }
metric() { grep -E "^$1 " "$TEXTFILE_DIR/etcd_backup.prom" 2>/dev/null | awk '{print $2}'; }

# 1. 正常系
reset
check "success: exit 0" 0 "$(run)"
check "success: 1 generation uploaded" 1 "$(gens)"
check "success: 3 objects" 3 "$(find "$S3/k8s2" -type f | wc -l | tr -d ' ')"
check "success: objects are encrypted (.age) with the recipient" "AGE-FAKE recipient=age1testrecipient" "$(head -1 "$(find "$S3/k8s2" -name 'etcd-snapshot.db.gz.age' | head -1)")"
check "success: local snapshot removed" "no" "$([ -e "$SNAPSHOT_PATH" ] && echo yes || echo no)"
check "success: metric last_run_success=1" 1 "$(metric etcd_backup_last_run_success)"
check "success: metric last_success_timestamp present" "yes" "$([ -n "$(metric etcd_backup_last_success_timestamp_seconds)" ] && echo yes || echo no)"
check "success: requests are signed (sigv4)" "no" "$(grep -q 'unsigned' "$work/out.txt" && echo yes || echo no)"
check "success: secret never logged" "no" "$(grep -rq 'SECRET-DO-NOT-LOG' "$work/out.txt" "$work/logger.log" "$TEXTFILE_DIR" && echo yes || echo no)"
check "success: no tmp dirs left" 0 "$(find "$work" -maxdepth 1 -name 'etcd-backup.*' | wc -l | tr -d ' ')"

# 2. ディスクの空きが足りない -> 何も作らず失敗
reset; export FAKE_FREE_MB=500 FAKE_DB_BYTES=1700000000
check "low disk: exit 1" 1 "$(run)"
check "low disk: nothing uploaded" 0 "$(find "$S3" -type f | wc -l | tr -d ' ')"
check "low disk: no snapshot file" "no" "$([ -e "$SNAPSHOT_PATH" ] && echo yes || echo no)"
check "low disk: metric last_run_success=0" 0 "$(metric etcd_backup_last_run_success)"

# 3. etcd が見つからない / snapshot 失敗 / 整合性の確認に失敗
reset; export FAKE_NO_ETCD=1
check "no etcd container: exit 1" 1 "$(run)"
reset; export FAKE_SNAP_FAIL=1
check "snapshot save fails: exit 1" 1 "$(run)"
check "snapshot save fails: nothing uploaded" 0 "$(find "$S3" -type f | wc -l | tr -d ' ')"
reset; export FAKE_STATUS_FAIL=1
check "snapshot status fails (corrupt): exit 1" 1 "$(run)"
check "snapshot status fails: nothing uploaded" 0 "$(find "$S3" -type f | wc -l | tr -d ' ')"
check "snapshot status fails: snapshot file removed" "no" "$([ -e "$SNAPSHOT_PATH" ] && echo yes || echo no)"

# 4. アップロード失敗: 失敗扱い、削除(prune)は行わない、直近の成功の時刻は引き継ぐ
reset
run >/dev/null
first_ok=$(metric etcd_backup_last_success_timestamp_seconds)
for t in 20200101T000000Z 20200102T000000Z 20200103T000000Z 20200104T000000Z 20200105T000000Z 20200106T000000Z; do add_gen $t; done
before=$(find "$S3" -type f | wc -l | tr -d ' ')
export FAKE_PUT_FAIL=pki.tar
sleep 1
check "upload fails: exit 1" 1 "$(run)"
check "upload fails: old generations NOT pruned" "$before" "$(( $(find "$S3" -type f | wc -l | tr -d ' ') - 1 ))"
check "upload fails: metric last_run_success=0" 0 "$(metric etcd_backup_last_run_success)"
check "upload fails: last_success_timestamp carried over" "$first_ok" "$(metric etcd_backup_last_success_timestamp_seconds)"

# 5. 保持: 古い世代を、MIN_KEEP を残して削除する
reset
for t in 20200101T000000Z 20200102T000000Z 20200103T000000Z 20200104T000000Z 20200105T000000Z 20200106T000000Z 20200107T000000Z 20200108T000000Z 20200109T000000Z 20200110T000000Z; do add_gen $t; done
check "prune: exit 0" 0 "$(run)"
check "prune: newest MIN_KEEP(5) generations remain (new + 4 newest old)" 5 "$(gens)"
check "prune: the new generation is kept" "yes" "$(ls "$S3/k8s2" | grep -qv '^2020' && echo yes || echo no)"
check "prune: oldest generation deleted" "no" "$([ -d "$S3/k8s2/20200101T000000Z" ] && [ -n "$(ls -A "$S3/k8s2/20200101T000000Z" 2>/dev/null)" ] && echo yes || echo no)"
check "prune: 4 newest old generations kept" "yes" "$([ -f "$S3/k8s2/20200110T000000Z/etcd-snapshot.db.gz.age" ] && [ -f "$S3/k8s2/20200107T000000Z/etcd-snapshot.db.gz.age" ] && echo yes || echo no)"

# 6. 保持期間内のものは、世代数が MIN_KEEP を超えても、削除しない
reset
for d in 1 2 3 4 5 6 7 8; do add_gen "$(date -u -d "-${d} hours" +%Y%m%dT%H%M%SZ)"; done
check "recent generations: exit 0" 0 "$(run)"
check "recent generations: none deleted (8 + 1 new)" 9 "$(gens)"

# 7. 世代数が MIN_KEEP 以下なら、古くても削除しない(時計の誤りなどで全滅しない)
reset
for t in 20200101T000000Z 20200102T000000Z 20200103T000000Z; do add_gen $t; done
check "few generations: exit 0" 0 "$(run)"
check "few generations: nothing deleted even if old" 4 "$(gens)"

# 8. 一覧が不完全(IsTruncated=true)なら、削除しない
reset
for t in 20200101T000000Z 20200102T000000Z 20200103T000000Z 20200104T000000Z 20200105T000000Z 20200106T000000Z 20200107T000000Z; do add_gen $t; done
export FAKE_TRUNCATED=true
check "truncated listing: exit 0 (backup itself succeeded)" 0 "$(run)"
check "truncated listing: nothing deleted" 8 "$(gens)"
check "truncated listing: logs the skip" "yes" "$(grep -q 'listing is incomplete' "$work/out.txt" && echo yes || echo no)"

# 9. 形式に合わない key や、ほかのノードのものは、削除しない
reset
for t in 20200101T000000Z 20200102T000000Z 20200103T000000Z 20200104T000000Z 20200105T000000Z 20200106T000000Z 20200107T000000Z; do add_gen $t; done
add_gen 20200101T000000Z k8s1
mkdir -p "$S3/k8s2/notes" && echo keep > "$S3/k8s2/notes/readme.txt"
run >/dev/null
check "other node's generation untouched" "yes" "$([ -f "$S3/k8s1/20200101T000000Z/etcd-snapshot.db.gz.age" ] && echo yes || echo no)"
check "non-generation key untouched" "yes" "$([ -f "$S3/k8s2/notes/readme.txt" ] && echo yes || echo no)"

# 10. 公開鍵が無ければ、始める前に失敗する(平文で上げない)
reset
check "no recipient: exit non-zero" "yes" "$(AGE_RECIPIENT="" bash "$script" >/dev/null 2>&1 && echo no || echo yes)"
check "no recipient: nothing uploaded" 0 "$(find "$S3" -type f | wc -l | tr -d ' ')"

# 12. ディスクのガード: 平文と暗号化の複製が一時的に両方ある(DB の 2 倍強)。DB + 1 GB だけの見積もりでは足りない
reset; export FAKE_DB_BYTES=2000000000 FAKE_FREE_MB=3100
check "disk guard counts 2x db (3100 MB free < 2*1907+1024): exit 1" 1 "$(run)"
check "disk guard: nothing uploaded" 0 "$(find "$S3" -type f | wc -l | tr -d ' ')"
reset; export FAKE_DB_BYTES=2000000000 FAKE_FREE_MB=5000
check "disk guard passes with enough room (5000 MB)" 0 "$(run)"

# 13. 中途半端な世代(アップロードの失敗の残り)は、最新の MIN_KEEP に数えない。完全な古い世代を、押し出さない
reset
for t in 20200101T000000Z 20200102T000000Z 20200103T000000Z 20200104T000000Z 20200105T000000Z; do add_gen $t; done   # 完全な古い 5 世代
for t in 20200201T000000Z 20200202T000000Z 20200203T000000Z 20200204T000000Z; do   # 新しいが、snapshot だけの 4 世代
  mkdir -p "$S3/k8s2/$t"; echo x > "$S3/k8s2/$t/etcd-snapshot.db.gz.age"
done
run >/dev/null
# 完全な世代は、古い 5 + 新しい 1 = 6 で、MIN_KEEP(5)を超える。最新の 5 完全世代(新 + 古い 4)が残り、最古の 1 つだけが消える。
# 修正前は、新しい中途半端な 4 世代が数えられ、完全な古い 5 世代が、全て消えていた。
check "keeps the newest 5 COMPLETE generations (partials are not counted)" 5 "$(gens)"
check "old complete generations survive (newest 4 of them)" "yes" "$([ -f "$S3/k8s2/20200102T000000Z/etcd-snapshot.db.gz.age" ] && [ -f "$S3/k8s2/20200105T000000Z/etcd-snapshot.db.gz.age" ] && echo yes || echo no)"
check "only the oldest complete generation is pruned" "no" "$([ -f "$S3/k8s2/20200101T000000Z/etcd-snapshot.db.gz.age" ] && echo yes || echo no)"
check "old partial generations (garbage) are pruned" "no" "$([ -f "$S3/k8s2/20200201T000000Z/etcd-snapshot.db.gz.age" ] && echo yes || echo no)"

# 14. 中断(TERM)されても、平文のスナップショットを残さない(検証の最中でも)
reset; export FAKE_STATUS_SLEEP=2
bash "$script" > "$work/out.txt" 2>&1 &
pid=$!
for i in $(seq 1 30); do [ -e "$SNAPSHOT_PATH" ] && break; sleep 0.1; done
check "snapshot exists while status is running" yes "$([ -e "$SNAPSHOT_PATH" ] && echo yes || echo no)"
kill -TERM "$pid"; wait "$pid" 2>/dev/null
check "TERM during validation: plaintext snapshot removed" no "$([ -e "$SNAPSHOT_PATH" ] && echo yes || echo no)"
check "TERM during validation: nothing uploaded" 0 "$(find "$S3" -type f | wc -l | tr -d ' ')"
unset FAKE_STATUS_SLEEP

# 15. MIN_KEEP が 0 や不正でも、全ての世代を消さない
reset
for t in 20200101T000000Z 20200102T000000Z 20200103T000000Z; do add_gen $t; done
MIN_KEEP=0 run >/dev/null
check "MIN_KEEP=0 is clamped to 1: the newest generation is kept" "yes" "$(ls "$S3/k8s2" | grep -qv '^2020' && echo yes || echo no)"
check "MIN_KEEP=0 still keeps at least one complete generation" "yes" "$([ "$(gens)" -ge 1 ] && echo yes || echo no)"

# 16. 一覧が複数ページ(既定の保持 14 日 x 毎時 x 3 オブジェクト = 1008 個 > 1000)でも、全ページを読んで、削除する
reset
for n in $(seq 1 60); do add_gen "2020$(printf '%02d' $(( (n - 1) / 28 + 1 )))$(printf '%02d' $(( (n - 1) % 28 + 1 )))T000000Z"; done
export FAKE_PAGE_SIZE=50     # 180 オブジェクトを、4 ページで返す
check "paginated listing: exit 0" 0 "$(run)"
check "paginated listing: pruned across pages (newest 5 complete generations remain)" 5 "$(gens)"
check "paginated listing: no 'incomplete' skip" "no" "$(grep -q 'listing is incomplete\|too many pages' "$work/out.txt" && echo yes || echo no)"
check "paginated listing: the new generation is kept" "yes" "$(ls "$S3/k8s2" | grep -qv '^2020' && echo yes || echo no)"

# 17. ページの途中で、トークンが無いまま truncated なら、削除しない(不完全な一覧では、削除しない)
reset
for t in 20200101T000000Z 20200102T000000Z 20200103T000000Z 20200104T000000Z 20200105T000000Z 20200106T000000Z 20200107T000000Z; do add_gen $t; done
export FAKE_PAGE_SIZE=5 FAKE_TRUNCATED=true
run >/dev/null
check "truncated without token: nothing deleted" 8 "$(gens)"
unset FAKE_PAGE_SIZE FAKE_TRUNCATED

# 11. 同時実行は、後のものがスキップされる
reset
( flock 9; sleep 2 ) 9>"$LOCK_FILE" &
sleep 0.3
check "concurrent run: skipped with exit 0" 0 "$(run)"
check "concurrent run: nothing uploaded" 0 "$(find "$S3" -type f | wc -l | tr -d ' ')"
wait

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
