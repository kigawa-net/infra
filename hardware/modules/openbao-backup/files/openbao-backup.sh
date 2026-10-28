#!/usr/bin/env bash
# OpenBao の Raft スナップショットを取り、age で暗号化して、Backblaze B2(Object Lock 付き・S3 互換 API)に置く。
# 設計: docs/openbao-implementation-design.md §7。手順と前提は、モジュールの README.md を参照。
#
#   1. 設定(/etc/openbao-backup/env)と、AppRole の資格情報(root のみ読める)を確認する
#   2. 今回書く世代(tier)を決める。6h は毎回。daily / weekly / monthly は、その期間のものが B2 に無いときだけ
#      (期間の最初の実行)。判定は HEAD で行うので、冪等。--reason のときは adhoc/<reason>/ だけ
#   3. AppRole でログインし(トークンはメモリだけに持つ)、/v1/sys/storage/raft/snapshot を、RAM 上の作業ディレクトリに
#      受け取る(エンドポイントを順に試し、最初に成功したものを使う)。トークンは直ちに revoke する
#   4. スナップショットの形式を確認し、age の公開鍵だけで暗号化する。平文は、暗号化の直後に消す
#   5. 暗号化したものを、決めた世代の数だけ B2 に PUT する(Object Lock の保持期間つき)。HEAD でサイズを確認し、
#      sha256 を `<key>.sha256` に置く。その sha256 が有れば、その世代は「完了」とみなす
#   6. 削除は一切しない。保持は、バケットの Object Lock と、B2 の Lifecycle ルール(手動設定)に任せる
#   7. node_exporter の textfile に、結果を書く(一時ファイルに書いてから rename)
#   8. HEALTHCHECK_URL があれば、成功で ping、失敗で <URL>/fail を送る(実行ホストが死んだときの、外部からの検知)
#
# 設定は /etc/openbao-backup/env(root のみ読める)から読む。公開鍵(AGE_RECIPIENT)だけを持ち、秘密鍵はホストに置かない。
# 資格情報・トークン・ping の URL は、curl の設定を標準入力(-K -)で渡す。コマンドライン(ps)にも、ログにも出さない。
set -uo pipefail
umask 077

ENV_FILE="${ENV_FILE:-/etc/openbao-backup/env}"
# shellcheck disable=SC1090
[ -r "$ENV_FILE" ] && . "$ENV_FILE"

B2_ENDPOINT="${B2_ENDPOINT:-}"
B2_REGION="${B2_REGION:-}"
B2_BUCKET="${B2_BUCKET:-}"
B2_ACCESS_KEY_ID="${B2_ACCESS_KEY_ID:-}"
B2_SECRET_ACCESS_KEY="${B2_SECRET_ACCESS_KEY:-}"
AGE_RECIPIENT="${AGE_RECIPIENT:-}"
BAO_ENDPOINTS="${BAO_ENDPOINTS:-}"
BAO_ROLE_ID_FILE="${BAO_ROLE_ID_FILE:-/etc/openbao-backup/role_id}"
BAO_SECRET_ID_FILE="${BAO_SECRET_ID_FILE:-/etc/openbao-backup/secret_id}"
OBJECT_LOCK_MODE="${OBJECT_LOCK_MODE:-GOVERNANCE}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
# 平文のスナップショットを置く場所。tmpfs(RAM)であること。systemd では RuntimeDirectory=openbao-backup
SNAPSHOT_BASE="${SNAPSHOT_BASE:-/run/openbao-backup}"
REQUIRE_TMPFS="${REQUIRE_TMPFS:-1}"
# 空に近い応答(エラーページなど)を、スナップショットとして上げない
MIN_SNAPSHOT_BYTES="${MIN_SNAPSHOT_BYTES:-1024}"
LOCK_FILE="${LOCK_FILE:-$SNAPSHOT_BASE/openbao-backup.lock}"

# 保持日数(Object Lock の保持期間。この日数より前に、実行ホストが消すことはない)
RETAIN_6H=7
RETAIN_DAILY=30
RETAIN_WEEKLY=84
RETAIN_MONTHLY=365
RETAIN_ADHOC=30
ALL_TIERS="6h daily weekly monthly adhoc"

REASON=""
REASON_SET=0
WORK=""
TOKEN=""
LOGIN_EP=""
ROLE_ID=""
SECRET_ID=""
TIERS_OK=""
SIZE_BYTES=0
START_TS=0
TIER_NAMES=()
TIER_KEYS=()
TIER_DAYS=()

log() { logger -t openbao-backup -- "$*" 2>/dev/null || true; echo "openbao-backup: $*" >&2; }

is_ok_tier() { case " $TIERS_OK " in *" $1 "*) return 0 ;; esac; return 1; }

write_metrics() { # 0|1: 直近の実行の結果を textfile に書く(一時ファイルに書いてから rename。失敗の時刻は、前回の成功を引き継ぐ)
  local ok="$1" now tmp dst t
  now=$(date -u +%s)
  mkdir -p "$TEXTFILE_DIR" 2>/dev/null || return 0
  dst="$TEXTFILE_DIR/openbao_backup.prom"
  tmp="$TEXTFILE_DIR/.openbao_backup.prom.$$"
  {
    echo "# HELP openbao_backup_last_run_success 直近の実行が成功したか (1/0)"
    echo "# TYPE openbao_backup_last_run_success gauge"
    echo "openbao_backup_last_run_success $ok"
    echo "# HELP openbao_backup_last_run_timestamp_seconds 直近の実行の時刻"
    echo "# TYPE openbao_backup_last_run_timestamp_seconds gauge"
    echo "openbao_backup_last_run_timestamp_seconds $now"
    echo "# HELP openbao_backup_duration_seconds 直近の実行にかかった時間"
    echo "# TYPE openbao_backup_duration_seconds gauge"
    echo "openbao_backup_duration_seconds $((now - START_TS))"
    echo "# HELP openbao_backup_size_bytes 直近にアップロードした、暗号化後のスナップショットのサイズ"
    echo "# TYPE openbao_backup_size_bytes gauge"
    echo "openbao_backup_size_bytes $SIZE_BYTES"
    echo "# HELP openbao_backup_last_success_timestamp_seconds 直近の成功の時刻(失敗のときは、前回の成功を引き継ぐ)"
    echo "# TYPE openbao_backup_last_success_timestamp_seconds gauge"
    if [ "$ok" = 1 ]; then
      echo "openbao_backup_last_success_timestamp_seconds $now"
    elif [ -r "$dst" ]; then
      grep -E '^openbao_backup_last_success_timestamp_seconds ' "$dst" 2>/dev/null || true
    fi
    echo "# HELP openbao_backup_tier_last_success_timestamp_seconds 世代(tier)ごとの直近の成功の時刻"
    echo "# TYPE openbao_backup_tier_last_success_timestamp_seconds gauge"
    for t in $ALL_TIERS; do
      if is_ok_tier "$t"; then
        echo "openbao_backup_tier_last_success_timestamp_seconds{tier=\"$t\"} $now"
      elif [ -r "$dst" ]; then
        grep -E "^openbao_backup_tier_last_success_timestamp_seconds\{tier=\"$t\"\} " "$dst" 2>/dev/null || true
      fi
    done
  } > "$tmp" 2>/dev/null && mv "$tmp" "$dst"
}

ping_health() { # "" | fail: 外部の死活監視に送る。URL は標準入力の設定で渡し、ログに出さない
  [ -n "$HEALTHCHECK_URL" ] || return 0
  local url="$HEALTHCHECK_URL"
  [ "${1:-}" = fail ] && url="${HEALTHCHECK_URL%/}/fail"
  printf 'url = "%s"\n' "$url" | curl -fsS -o /dev/null --max-time 15 --retry 2 -K - >/dev/null 2>&1 \
    || log "healthcheck ping failed (ignored)"
}

fail() { # 失敗の記録(メトリクスと、外部への通知)のあと、終了する。作業ディレクトリは EXIT の trap が消す
  log "FAILED: $*"
  write_metrics 0
  ping_health fail
  exit 1
}

cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT
trap 'fail "terminated by signal"' TERM INT

usage() { echo "usage: openbao-backup.sh [--reason <text>]" >&2; }

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason)
        [ $# -ge 2 ] || { usage; exit 2; }
        REASON="$2"; REASON_SET=1; shift 2 ;;
      --reason=*) REASON="${1#--reason=}"; REASON_SET=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 2 ;;
    esac
  done
  if [ "$REASON_SET" = 1 ] && ! [[ "$REASON" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    echo "openbao-backup: --reason は英数字で始まり、英数字 . _ - のみ(64 文字以内)" >&2
    exit 2
  fi
}

check_config() {
  local t ep derived
  [[ "$B2_ENDPOINT" =~ ^https://s3\.([a-z0-9-]+)\.backblazeb2\.com$ ]] \
    || fail "B2_ENDPOINT は https://s3.<region>.backblazeb2.com の形式"
  derived="${BASH_REMATCH[1]}"
  [ -n "$B2_REGION" ] || B2_REGION="$derived"
  [ "$B2_REGION" = "$derived" ] || fail "B2_REGION が B2_ENDPOINT のリージョン($derived)と違う"
  [[ "$B2_BUCKET" =~ ^[a-z0-9][a-z0-9-]{2,62}$ ]] || fail "B2_BUCKET が未設定か不正"
  [[ "$B2_ACCESS_KEY_ID" =~ ^[A-Za-z0-9+/=_-]{8,}$ ]] || fail "B2_ACCESS_KEY_ID が未設定か不正"
  [[ "$B2_SECRET_ACCESS_KEY" =~ ^[A-Za-z0-9+/=_-]{8,}$ ]] || fail "B2_SECRET_ACCESS_KEY が未設定か不正"
  [[ "$AGE_RECIPIENT" =~ ^age1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58}$ ]] \
    || fail "AGE_RECIPIENT は age1 で始まる公開鍵(62 文字)"
  case "$OBJECT_LOCK_MODE" in COMPLIANCE|GOVERNANCE) ;; *) fail "OBJECT_LOCK_MODE は COMPLIANCE か GOVERNANCE" ;; esac
  [ -n "$BAO_ENDPOINTS" ] || fail "BAO_ENDPOINTS が未設定"
  for ep in $BAO_ENDPOINTS; do
    [[ "$ep" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] || fail "BAO_ENDPOINTS の形式が不正(https://host:port): $ep"
  done
  if [ -n "$HEALTHCHECK_URL" ]; then
    [[ "$HEALTHCHECK_URL" =~ ^https?:// ]] || fail "HEALTHCHECK_URL の形式が不正(値は表示しない)"
  fi
  for t in curl age sha256sum openssl tar od base64 flock awk; do
    command -v "$t" >/dev/null 2>&1 || fail "$t がありません"
  done
}

read_approle() { # root のみ読める2つのファイル。値は変数に持つだけで、表示しない
  ROLE_ID=""; SECRET_ID=""
  [ -r "$BAO_ROLE_ID_FILE" ] && ROLE_ID=$(tr -d ' \r\n' < "$BAO_ROLE_ID_FILE")
  [ -r "$BAO_SECRET_ID_FILE" ] && SECRET_ID=$(tr -d ' \r\n' < "$BAO_SECRET_ID_FILE")
  [[ "$ROLE_ID" =~ ^[A-Za-z0-9._-]{8,}$ ]] || fail "AppRole の role_id が無いか不正($BAO_ROLE_ID_FILE)"
  [[ "$SECRET_ID" =~ ^[A-Za-z0-9._-]{8,}$ ]] || fail "AppRole の secret_id が無いか不正($BAO_SECRET_ID_FILE)"
}

# --- B2(S3 互換)。curl の --aws-sigv4 で署名する。資格情報は設定(標準入力)で渡す
s3_config() { # $1 = key
  printf 'url = "%s/%s/%s"\n' "$B2_ENDPOINT" "$B2_BUCKET" "$1"
  printf 'user = "%s:%s"\n' "$B2_ACCESS_KEY_ID" "$B2_SECRET_ACCESS_KEY"
  printf 'aws-sigv4 = "aws:amz:%s:s3"\n' "$B2_REGION"
}

s3_head() { # $1 = key -> "<HTTP code> <Content-Length>"(無ければ空)
  local out code len
  out=$( { s3_config "$1"; } | curl -sS --max-time 120 -K - -I -D - -o /dev/null -w '\n%{http_code}' 2>/dev/null ) || true
  code=$(printf '%s\n' "$out" | tail -n 1)
  len=$(printf '%s\n' "$out" | tr -d '\r' | awk 'tolower($1)=="content-length:" {v=$2} END {print v}')
  printf '%s %s\n' "${code:-000}" "${len:-}"
}

s3_put() { # $1 = ローカルのファイル, $2 = key, $3 = retain-until(UTC の ISO 8601)。成功なら 0
  local file="$1" key="$2" until="$3" sha md5 code
  sha=$(sha256sum "$file" | awk '{print $1}')
  md5=$(openssl dgst -md5 -binary "$file" | base64 | tr -d '\n')
  code=$( { s3_config "$key"
            printf 'header = "x-amz-object-lock-mode: %s"\n' "$OBJECT_LOCK_MODE"
            printf 'header = "x-amz-object-lock-retain-until-date: %s"\n' "$until"
            printf 'header = "x-amz-content-sha256: %s"\n' "$sha"
            printf 'header = "Content-MD5: %s"\n' "$md5"
          } | curl -sS --max-time 900 -K - -X PUT --upload-file "$file" -o /dev/null -w '%{http_code}' 2>/dev/null ) || true
  [ "$code" = 200 ]
}

# 期間の世代があるか(sha256 の側ファイルで判定する)。あれば 0、無ければ 1。HEAD が失敗したら、中止する
period_done() { # $1 = key
  local hc
  read -r hc _ <<< "$(s3_head "$1")"
  case "$hc" in
    200) return 0 ;;
    404) return 1 ;;
    *) fail "HEAD $1 が HTTP ${hc:-000} を返した(世代の有無が分からないので、何も上げない)" ;;
  esac
}

# --- OpenBao(HTTP API)。トークンは、変数(メモリ)だけに持つ
vault_login() {
  local ep out code body
  for ep in $BAO_ENDPOINTS; do
    ep="${ep%/}"
    out=$( {
      printf 'url = "%s/v1/auth/approle/login"\n' "$ep"
      printf 'header = "Content-Type: application/json"\n'
      printf 'data-binary = "{\\"role_id\\":\\"%s\\",\\"secret_id\\":\\"%s\\"}"\n' "$ROLE_ID" "$SECRET_ID"
    } | curl -sS --max-time 30 -K - -w '\n%{http_code}' 2>/dev/null ) || true
    code=$(printf '%s\n' "$out" | tail -n 1)
    body=$(printf '%s\n' "$out" | sed '$d')
    if [ "$code" = 200 ]; then
      TOKEN=$(printf '%s' "$body" | sed -nE 's/.*"client_token":"([^"]+)".*/\1/p')
      # トークンは curl の設定にそのまま載せるので、想定した文字だけを受け付ける
      [[ "$TOKEN" =~ ^[A-Za-z0-9._-]+$ ]] || TOKEN=""
      unset out body
      if [ -n "$TOKEN" ]; then LOGIN_EP="$ep"; log "AppRole login ok ($ep)"; return 0; fi
    fi
    unset out body
    log "AppRole login failed at $ep (HTTP ${code:-000})"
  done
  return 1
}

revoke_token() { # 成否は、バックアップの成否に影響させない(トークンは TTL で切れる)
  local ep code
  [ -n "$TOKEN" ] || return 0
  for ep in $LOGIN_EP $BAO_ENDPOINTS; do
    code=$( { printf 'url = "%s/v1/auth/token/revoke-self"\n' "$ep"
              printf 'header = "X-Vault-Token: %s"\n' "$TOKEN"
            } | curl -sS --max-time 30 -K - -X POST -o /dev/null -w '%{http_code}' 2>/dev/null ) || true
    if [ "$code" = 204 ] || [ "$code" = 200 ]; then TOKEN=""; log "token revoked"; return 0; fi
  done
  TOKEN=""
  log "WARNING: token revoke failed (the token expires by its TTL)"
}

take_snapshot() { # $1 = 出力先。アクティブノードが応答するまで、エンドポイントを順に試す
  local snap="$1" ep code
  for ep in $BAO_ENDPOINTS; do
    ep="${ep%/}"
    rm -f "$snap"
    code=$( { printf 'url = "%s/v1/sys/storage/raft/snapshot"\n' "$ep"
              printf 'header = "X-Vault-Token: %s"\n' "$TOKEN"
            } | curl -sS --max-time 900 -K - -o "$snap" -w '%{http_code}' 2>/dev/null ) || true
    if [ "$code" = 200 ] && [ -s "$snap" ]; then log "snapshot downloaded from $ep"; return 0; fi
    log "snapshot from $ep failed (HTTP ${code:-000})"
  done
  rm -f "$snap"
  return 1
}

validate_snapshot() { # Raft スナップショットは gzip の tar(meta.json と state.bin を含む)。bao バイナリは使わない
  local f="$1" size magic names
  size=$(wc -c < "$f" | tr -d ' ')
  [ "$size" -ge "$MIN_SNAPSHOT_BYTES" ] || { log "snapshot is too small: ${size} bytes"; return 1; }
  magic=$(od -An -N2 -tx1 "$f" | tr -d ' \n')
  [ "$magic" = 1f8b ] || { log "snapshot is not gzip (magic=${magic})"; return 1; }
  names=$(tar -tzf "$f" 2>/dev/null) || { log "snapshot archive is broken"; return 1; }
  printf '%s\n' "$names" | grep -qE '(^|/)meta\.json$' || { log "snapshot has no meta.json"; return 1; }
  printf '%s\n' "$names" | grep -qE '(^|/)state\.bin$' || { log "snapshot has no state.bin"; return 1; }
  return 0
}

add_tier() { TIER_NAMES+=("$1"); TIER_KEYS+=("$2"); TIER_DAYS+=("$3"); }

plan_tiers() { # 今回書く世代を決める。期間の名前は UTC で決まる(決定的)
  local now stamp day week month spec t k d
  now="$START_TS"
  stamp=$(date -u -d "@$now" +%Y%m%dT%H%M%SZ)
  day=$(date -u -d "@$now" +%Y-%m-%d)
  week=$(date -u -d "@$now" +%G-W%V)     # ISO 週(月曜始まり)
  month=$(date -u -d "@$now" +%Y-%m)
  if [ "$REASON_SET" = 1 ]; then
    add_tier adhoc "adhoc/${REASON}/${stamp}.raft.snap.age" "$RETAIN_ADHOC"
    return 0
  fi
  add_tier 6h "6h/${stamp}.raft.snap.age" "$RETAIN_6H"
  for spec in "daily|daily/${day}.raft.snap.age|$RETAIN_DAILY" \
              "weekly|weekly/${week}.raft.snap.age|$RETAIN_WEEKLY" \
              "monthly|monthly/${month}.raft.snap.age|$RETAIN_MONTHLY"; do
    IFS='|' read -r t k d <<< "$spec"
    # 期間の世代が既にあれば、書かない(その期間の最初の実行で書かれている)
    if period_done "${k}.sha256"; then continue; fi
    add_tier "$t" "$k" "$d"
  done
}

main() {
  START_TS=$(date -u +%s)
  parse_args "$@"
  check_config
  read_approle

  mkdir -p "$SNAPSHOT_BASE" && chmod 0700 "$SNAPSHOT_BASE" || fail "作業ディレクトリ $SNAPSHOT_BASE を作れません"
  exec 9>"$LOCK_FILE" || fail "lock file を開けません"
  flock -n 9 || { log "another run is in progress; skipping"; exit 0; }
  if [ "$REQUIRE_TMPFS" = 1 ]; then
    case "$(stat -f -c %T "$SNAPSHOT_BASE" 2>/dev/null)" in
      tmpfs|ramfs) ;;
      *) fail "$SNAPSHOT_BASE が tmpfs / ramfs ではない(平文を永続ディスクに置かない)" ;;
    esac
  fi
  WORK=$(mktemp -d "$SNAPSHOT_BASE/run.XXXXXX") || fail "mktemp に失敗"
  chmod 0700 "$WORK"

  plan_tiers
  [ "${#TIER_KEYS[@]}" -gt 0 ] || { log "no tier is due"; write_metrics 1; ping_health; exit 0; }
  log "tiers due: ${TIER_NAMES[*]}"

  login_and_snapshot
  local snap="$WORK/raft.snap" enc="$WORK/raft.snap.age" i t k d until side enc_sha hc hl
  # login_and_snapshot は、$WORK/raft.snap を作る(平文は、このあと暗号化して消す)
  validate_snapshot "$snap" || { rm -f "$snap"; fail "snapshot validation failed"; }
  age -r "$AGE_RECIPIENT" -o "$enc" < "$snap" || { rm -f "$snap"; fail "age encryption failed"; }
  rm -f "$snap"
  head -n 1 "$enc" | grep -qx 'age-encryption.org/v1' || fail "encrypted file has no age header"
  SIZE_BYTES=$(wc -c < "$enc" | tr -d ' ')
  enc_sha=$(sha256sum "$enc" | awk '{print $1}')
  side="$WORK/side.sha256"

  for i in "${!TIER_KEYS[@]}"; do
    t=${TIER_NAMES[$i]}; k=${TIER_KEYS[$i]}; d=${TIER_DAYS[$i]}
    until=$(date -u -d "@$((START_TS + d * 86400))" +%Y-%m-%dT%H:%M:%SZ) || fail "retain-until の計算に失敗"
    s3_put "$enc" "$k" "$until" || fail "upload failed: $k"
    read -r hc hl <<< "$(s3_head "$k")"
    [ "$hc" = 200 ] && [ "${hl:-}" = "$SIZE_BYTES" ] \
      || fail "uploaded size mismatch: $k local=${SIZE_BYTES} remote=${hl:-none} (HTTP ${hc:-000})"
    printf '%s  %s\n' "$enc_sha" "$(basename "$k")" > "$side"
    s3_put "$side" "${k}.sha256" "$until" || fail "upload failed: ${k}.sha256"
    TIERS_OK="$TIERS_OK $t"
    log "uploaded $k (${SIZE_BYTES} bytes, tier $t, ${OBJECT_LOCK_MODE} until $until)"
  done

  write_metrics 1
  ping_health
  log "done in $(( $(date -u +%s) - START_TS ))s"
  exit 0
}

login_and_snapshot() {
  vault_login || fail "AppRole login failed at all endpoints"
  if ! take_snapshot "$WORK/raft.snap"; then
    revoke_token
    fail "snapshot failed at all endpoints"
  fi
  revoke_token
}

main "$@"
