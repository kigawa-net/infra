#!/usr/bin/env bash
# etcd のスナップショットを取り、圧縮・暗号化(age の公開鍵)して、R2 に置く (issue #189)。
#
#   1. ディスクの空きを確認し、足りなければ、何も作らず失敗する
#   2. etcd のコンテナ内の etcdctl で snapshot save し、etcdutl で整合性を確認する
#   3. gzip -> age で暗号化して、R2 へ PUT する(中間ファイルは作らない)。
#      /etc/kubernetes/pki と admin.conf(control-plane の再構築に必要)も、同じ形で別のファイルにする
#   4. アップロードしたものを HEAD で確認する
#   5. 保持期間を過ぎた古いものを削除する(最新の MIN_KEEP 個は、必ず残す。一覧が不完全なら、削除しない)
#   6. node_exporter の textfile に、結果を書く
#
# 設定は /etc/etcd-backup/env(root のみ読める)から読む。公開鍵(AGE_RECIPIENT)だけを持ち、
# 秘密鍵はノードに置かない(ノードが侵害されても、過去のバックアップは読めない)。
set -uo pipefail

ENV_FILE="${ENV_FILE:-/etc/etcd-backup/env}"
# shellcheck disable=SC1090
[ -r "$ENV_FILE" ] && . "$ENV_FILE"

: "${R2_ENDPOINT:?R2_ENDPOINT is required}"
: "${R2_BUCKET:?R2_BUCKET is required}"
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is required}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is required}"
: "${AGE_RECIPIENT:?AGE_RECIPIENT is required}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
MIN_KEEP="${MIN_KEEP:-48}"
# 0 以下だと、全ての世代を消せてしまう。最低 1 世代は、必ず残す
case "$MIN_KEEP" in ''|*[!0-9]*) MIN_KEEP=48 ;; esac
[ "$MIN_KEEP" -ge 1 ] || MIN_KEEP=1
SNAPSHOT_PATH="${SNAPSHOT_PATH:-/var/lib/etcd/.etcd-backup-snapshot.db}"   # etcd コンテナの /var/lib/etcd(hostPath)
PKI_DIR="${PKI_DIR:-/etc/kubernetes}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
MIN_FREE_MB_EXTRA="${MIN_FREE_MB_EXTRA:-1024}"
LOCK_FILE="${LOCK_FILE:-/run/etcd-backup.lock}"
export CONTAINER_RUNTIME_ENDPOINT="${CONTAINER_RUNTIME_ENDPOINT:-unix:///run/containerd/containerd.sock}"

CRICTL="${CRICTL:-crictl}"
CURL="${CURL:-curl}"
AGE="${AGE:-age}"
LOGGER="${LOGGER:-logger}"
DF="${DF:-df}"
DATE="${DATE:-date}"

log() { "$LOGGER" -t etcd-backup -- "$*" 2>/dev/null || true; echo "etcd-backup: $*" >&2; }

start_ts=$("$DATE" +%s)
size_bytes=0
write_metrics() { # 0|1
  local ok="$1" now
  now=$("$DATE" +%s)
  mkdir -p "$TEXTFILE_DIR" 2>/dev/null || return 0
  local tmp="$TEXTFILE_DIR/.etcd_backup.prom.$$"
  {
    echo "# HELP etcd_backup_last_run_success 直近の実行が成功したか (1/0)"
    echo "# TYPE etcd_backup_last_run_success gauge"
    echo "etcd_backup_last_run_success $ok"
    echo "# HELP etcd_backup_last_run_timestamp_seconds 直近の実行の時刻"
    echo "# TYPE etcd_backup_last_run_timestamp_seconds gauge"
    echo "etcd_backup_last_run_timestamp_seconds $now"
    echo "# HELP etcd_backup_duration_seconds 直近の実行にかかった時間"
    echo "# TYPE etcd_backup_duration_seconds gauge"
    echo "etcd_backup_duration_seconds $((now - start_ts))"
    echo "# HELP etcd_backup_snapshot_bytes 直近のスナップショット(圧縮・暗号化後)のサイズ"
    echo "# TYPE etcd_backup_snapshot_bytes gauge"
    echo "etcd_backup_snapshot_bytes $size_bytes"
    if [ "$ok" = 1 ]; then
      echo "# HELP etcd_backup_last_success_timestamp_seconds 直近の成功の時刻"
      echo "# TYPE etcd_backup_last_success_timestamp_seconds gauge"
      echo "etcd_backup_last_success_timestamp_seconds $now"
    elif [ -r "$TEXTFILE_DIR/etcd_backup.prom" ]; then
      # 失敗したときは、直近の成功の時刻を引き継ぐ(アラートの基準)
      grep -E '^(# (HELP|TYPE) etcd_backup_last_success_timestamp_seconds|etcd_backup_last_success_timestamp_seconds )' \
        "$TEXTFILE_DIR/etcd_backup.prom" 2>/dev/null
    fi
  } > "$tmp" 2>/dev/null && mv "$tmp" "$TEXTFILE_DIR/etcd_backup.prom"
}

fail() { log "FAILED: $*"; write_metrics 0; exit 1; }   # 後始末は、EXIT の trap が行う

exec 9>"$LOCK_FILE"
flock -n 9 || { log "another run is in progress; skipping"; exit 0; }

# --- S3 (R2) の操作。curl の --aws-sigv4 で署名する(追加のパッケージは不要)
s3() { # curl の引数
  "$CURL" -sS --max-time "${CURL_MAX_TIME:-900}" --aws-sigv4 "aws:amz:auto:s3" \
    --user "${R2_ACCESS_KEY_ID}:${R2_SECRET_ACCESS_KEY}" "$@"
}
s3_put() { # ローカルのパイプ入力ではなく、ファイルから送る。成功なら 0
  local file="$1" key="$2" code
  code=$(s3 -o /dev/null -w '%{http_code}' -X PUT --upload-file "$file" "${R2_ENDPOINT}/${R2_BUCKET}/${key}") || return 1
  [ "$code" = "200" ]
}
s3_size() { # key -> Content-Length
  s3 -I "${R2_ENDPOINT}/${R2_BUCKET}/$1" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:" {print $2}'
}

# --- 後始末は、最初に登録する(スナップショットの検証中に、systemd のタイムアウトで止められても、
#     平文のスナップショットを残さない)。TERM / INT も、EXIT の trap を通す。
work=""
cleanup_files() { [ -n "$work" ] && rm -rf "$work"; rm -f "$SNAPSHOT_PATH"; }
trap cleanup_files EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
rm -f "$SNAPSHOT_PATH"   # 前回の中断の残りがあれば消す

# --- 1. ディスクの空き: 平文のスナップショットと、圧縮・暗号化した複製が、一時的に両方ある。
#     最悪(ほとんど圧縮できない)で、DB の 2 倍強。スナップショットの置き場所と、作業用の場所の、両方を確認する
free_mb_of() { "$DF" -Pm "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }
# --- 2. etcd のコンテナ
cid=$("$CRICTL" ps --name '^etcd$' -q 2>/dev/null | head -1)
[ -n "$cid" ] || fail "etcd container not found"
etcdctl() { "$CRICTL" exec "$cid" etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key "$@"; }
db_bytes=$(etcdctl endpoint status -w json 2>/dev/null | grep -o '"dbSize":[0-9]*' | head -1 | cut -d: -f2)
[ -n "${db_bytes:-}" ] || fail "cannot read etcd dbSize (is etcd healthy?)"
need_mb=$(( 2 * db_bytes / 1048576 + MIN_FREE_MB_EXTRA ))
for dir in "$(dirname "$SNAPSHOT_PATH")" "${TMPDIR:-/var/tmp}"; do
  free_mb=$(free_mb_of "$dir")
  if [ -z "${free_mb:-}" ] || [ "$free_mb" -lt "$need_mb" ]; then
    fail "not enough free disk on ${dir}: ${free_mb:-?} MB free, need ${need_mb} MB (2 x db ${db_bytes} bytes + ${MIN_FREE_MB_EXTRA} MB)"
  fi
done

ts=$("$DATE" -u +%Y%m%dT%H%M%SZ)
prefix="${NODE_NAME}/${ts}"
etcdctl snapshot save "$SNAPSHOT_PATH" >/dev/null 2>&1 || fail "etcdctl snapshot save failed"
# kubeadm の etcd イメージには etcdutl が無いので、etcd 3.5 の etcdctl snapshot status(非推奨だが動作する)で確かめる
status=$(etcdctl snapshot status "$SNAPSHOT_PATH" -w json 2>/dev/null) \
  || fail "etcdctl snapshot status failed (snapshot is corrupt?)"
log "snapshot ok: $status"

# --- 3. 圧縮 -> 暗号化 -> アップロード
work=$(mktemp -d "${TMPDIR:-/var/tmp}/etcd-backup.XXXXXX") || fail "mktemp failed"
gzip -1 -c "$SNAPSHOT_PATH" | "$AGE" -r "$AGE_RECIPIENT" -o "$work/etcd-snapshot.db.gz.age" || fail "compress/encrypt failed"
rm -f "$SNAPSHOT_PATH"
tar -C "$PKI_DIR" -c pki admin.conf 2>/dev/null | gzip -1 | "$AGE" -r "$AGE_RECIPIENT" -o "$work/pki.tar.gz.age" \
  || fail "pki archive failed"
echo "$status" | "$AGE" -r "$AGE_RECIPIENT" -o "$work/snapshot-status.json.age" || fail "status encrypt failed"

for f in etcd-snapshot.db.gz.age pki.tar.gz.age snapshot-status.json.age; do
  s3_put "$work/$f" "${prefix}/${f}" || fail "upload failed: ${prefix}/${f}"
  local_size=$(wc -c < "$work/$f" | tr -d ' ')
  remote_size=$(s3_size "${prefix}/${f}")
  [ "$remote_size" = "$local_size" ] || fail "uploaded size mismatch: ${prefix}/${f} local=${local_size} remote=${remote_size:-none}"
  [ "$f" = "etcd-snapshot.db.gz.age" ] && size_bytes="$local_size"
done
log "uploaded ${prefix}/ (snapshot ${size_bytes} bytes)"

# --- 5. 保持期間を過ぎたものを削除(失敗しても、バックアップ自体は成功として扱う)
prune() {
  local listing page truncated token pages_done cutoff ts_list n_keep g k complete_list keys
  # 一覧は、1 回に最大 1000 オブジェクト。1 世代が 3 オブジェクトなので、毎時で 14 日分(1008 個)で超える。
  # 全てのページを取れたときだけ、削除する(途中までだと、完全な世代を、不完全と誤認しかねない)。
  listing=""; token=""; pages_done=false
  for _ in $(seq 1 200); do
    if [ -n "$token" ]; then
      page=$(s3 -G --data-urlencode "list-type=2" --data-urlencode "prefix=${NODE_NAME}/" \
        --data-urlencode "continuation-token=${token}" "${R2_ENDPOINT}/${R2_BUCKET}/") || { log "prune skipped: list failed"; return 0; }
    else
      page=$(s3 -G --data-urlencode "list-type=2" --data-urlencode "prefix=${NODE_NAME}/" \
        "${R2_ENDPOINT}/${R2_BUCKET}/") || { log "prune skipped: list failed"; return 0; }
    fi
    listing="${listing}${page}"$'\n'
    truncated=$(echo "$page" | grep -o '<IsTruncated>[a-z]*</IsTruncated>' | sed -E 's/<[^>]*>//g')
    if [ "$truncated" = "false" ]; then pages_done=true; break; fi
    token=$(echo "$page" | grep -o '<NextContinuationToken>[^<]*</NextContinuationToken>' | sed -E 's/<[^>]*>//g')
    if [ "$truncated" != "true" ] || [ -z "$token" ]; then
      log "prune skipped: listing is incomplete (IsTruncated=${truncated:-unknown}, token=${token:+present})"; return 0
    fi
  done
  $pages_done || { log "prune skipped: too many pages"; return 0; }
  keys=$(echo "$listing" | grep -o '<Key>[^<]*</Key>' | sed -E 's/<[^>]*>//g')
  # 世代(タイムスタンプのディレクトリ)の一覧。名前の形式に合うものだけを対象にする。
  # 「完全な世代」= 3 つのファイルが全て揃っているもの。アップロードに失敗した、中途半端な世代は、
  # 最新の MIN_KEEP 世代に数えない(数えると、失敗が続いたときに、完全な古い世代が押し出されて消える)。
  ts_list=$(echo "$keys" | sed -nE "s#^${NODE_NAME}/([0-9]{8}T[0-9]{6}Z)/.*#\1#p" | sort -u)
  complete_list=""
  for g in $ts_list; do
    if echo "$keys" | grep -qx "${NODE_NAME}/${g}/etcd-snapshot.db.gz.age" \
      && echo "$keys" | grep -qx "${NODE_NAME}/${g}/pki.tar.gz.age" \
      && echo "$keys" | grep -qx "${NODE_NAME}/${g}/snapshot-status.json.age"; then
      complete_list="${complete_list}${g}"$'\n'
    fi
  done
  n_keep=$(echo -n "$complete_list" | grep -c . || true)
  if [ "$n_keep" -le "$MIN_KEEP" ]; then log "prune: ${n_keep} complete generations <= MIN_KEEP(${MIN_KEEP}); nothing to delete"; return 0; fi
  cutoff=$("$DATE" -u -d "-${RETENTION_DAYS} days" +%Y%m%dT%H%M%SZ)
  # 完全な世代の、新しい方から MIN_KEEP 個は残す。それ以外(古い完全な世代と、古い中途半端な世代)のうち、
  # cutoff より古いものを削除する
  local old kept
  kept=$(echo -n "$complete_list" | sort -r | head -n "$MIN_KEEP")
  old=$(echo "$ts_list" | sort -r | grep -vxF "$kept" | awk -v c="$cutoff" '$1 < c')
  local deleted=0
  for g in $old; do
    for k in $(echo "$keys" | grep "^${NODE_NAME}/${g}/"); do
      if s3 -o /dev/null -X DELETE "${R2_ENDPOINT}/${R2_BUCKET}/${k}"; then deleted=$((deleted + 1)); else log "prune: delete failed: $k"; fi
    done
  done
  log "prune: deleted ${deleted} objects older than ${cutoff} (kept newest ${MIN_KEEP} generations)"
}
prune

write_metrics 1
log "done in $(( $("$DATE" +%s) - start_ts ))s"
exit 0
