#!/bin/bash
# Karmada の外部 etcd のメンバー(IONOS = etcd #3)を、冪等に構成し、必要なら learner として参加させる(kigawa-net/kigawa-net-k8s#272)。
#
# やること:
#   1. etcd / etcdctl を、指定バージョンで入れる(すでに同じバージョンなら何もしない)
#   2. etcd ユーザーとデータディレクトリを用意する
#   3. 証明書(ca.crt / tls.crt / tls.key)が、あらかじめ置かれ、etcd ユーザーが読めることを確認する(この IaC は、秘密鍵を扱わない)
#   4. systemd ユニットと環境ファイルを、ステージされた内容に揃える
#   5. JOIN=1 で、まだ参加していなければ、既存のメンバーに `member add --learner` して、起動する(JOIN=0 なら、ここまで)
#
# やらないこと:
#   - learner の promote。voter が 1 つのクラスターに、2 つ目の voter を足すと、quorum が 2 になり、
#     どちらかが止まるだけで書き込みが止まる。ほかの learner も追いついてから、続けて promote する(手動、別の判断)。
#
# 参加の途中で失敗したら、登録(learner)を取り消してから、ローカルのデータを消す。取り消しを確認できないときは、
# データを残して、手動で直す手順を表示する(登録が残ったまま、データだけ消えると、再実行で回復できなくなるため)。
#
# 設定は、環境変数で受け取る(Terraform がステージする。テストでは、パスをテスト用に差し替える)。
set -euo pipefail

: "${MEMBER_NAME:?}" "${PEER_URL:?}" "${SEED_ENDPOINTS:?}" "${ETCD_VERSION:?}" "${TARBALL_SHA256:?}" "${CERT_IP:?}"
STAGE_DIR="${STAGE_DIR:?}"
JOIN="${JOIN:-0}"
ETC_DIR="${ETC_DIR:-/etc/etcd}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
DATA_DIR="${DATA_DIR:-/var/lib/karmada-etcd}"
UNIT_PATH="${UNIT_PATH:-/etc/systemd/system/karmada-etcd.service}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
WAIT_SECONDS="${WAIT_SECONDS:-120}"
ETCDCTL="${ETCDCTL:-$BIN_DIR/etcdctl}"
LOCAL_ENDPOINT="https://$CERT_IP:2379"

log() { echo "karmada-etcd-member: $*"; }
die() { echo "karmada-etcd-member: ABORT: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || [ "${ALLOW_NON_ROOT:-}" = 1 ] || die "root で実行すること(ssh_user = root)"

ctl() {
  "$ETCDCTL" --endpoints="$SEED_ENDPOINTS" --cacert="$ETC_DIR/pki/ca.crt" --cert="$ETC_DIR/pki/tls.crt" --key="$ETC_DIR/pki/tls.key" "$@"
}

# ID は、先頭に空白が付くことがある(etcdctl は %16x で出力する)ので、取り除く
own_entry() {
  # OFS を ", " にする(既定の空白だと、$1 を書き換えたときに、行の区切りが壊れる)
  ctl member list -w simple | awk -F', ' -v OFS=', ' -v n="$MEMBER_NAME" -v p="$PEER_URL" \
    '$3 == n || $4 == p { gsub(/^ +| +$/, "", $1); print }'
}

# 所有者を指定して作る。テスト(root でない)では、所有者の指定を外す
install_dir() {
  if [ "${ALLOW_NON_ROOT:-}" = 1 ]; then install -d -m "$1" "${@:4}"; else install -d -o "$2" -g "$3" -m "$1" "${@:4}"; fi
}

# --- 1. バイナリ -------------------------------------------------------------
installed=""
if [ -x "$BIN_DIR/etcd" ]; then
  installed=$("$BIN_DIR/etcd" --version 2>/dev/null | sed -n 's/^etcd Version: //p' | head -1)
fi
if [ "$installed" = "$ETCD_VERSION" ] && [ -x "$ETCDCTL" ]; then
  log "etcd $ETCD_VERSION は、すでに入っています"
else
  log "etcd $ETCD_VERSION を入れます(現在: ${installed:-なし})"
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/etcd.tgz" "https://github.com/etcd-io/etcd/releases/download/v$ETCD_VERSION/etcd-v$ETCD_VERSION-linux-amd64.tar.gz"
  echo "$TARBALL_SHA256  $tmp/etcd.tgz" | sha256sum -c - >/dev/null || { rm -rf "$tmp"; die "tarball の SHA256 が一致しません"; }
  tar xzf "$tmp/etcd.tgz" -C "$tmp" --strip-components=1 "etcd-v$ETCD_VERSION-linux-amd64/etcd" "etcd-v$ETCD_VERSION-linux-amd64/etcdctl"
  install -m 0755 "$tmp/etcd" "$tmp/etcdctl" "$BIN_DIR/"
  rm -rf "$tmp"
fi

# --- 2. ユーザーとディレクトリ ---------------------------------------------------
id etcd >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin etcd
# etcd ユーザーが、/etc/etcd と pki を辿れるようにする(root:root の 0750 だと、etcd が証明書を読めず、起動に失敗する)
install_dir 0750 root etcd "$ETC_DIR" "$ETC_DIR/pki"
install_dir 0700 etcd etcd "$DATA_DIR"

# --- 3. 証明書(あらかじめ置かれていること) ------------------------------------
for f in ca.crt tls.crt tls.key; do
  [ -s "$ETC_DIR/pki/$f" ] || die "$ETC_DIR/pki/$f がありません(証明書は、この IaC の外で用意する。kigawa-net-k8s#268 の手順)"
done
if command -v openssl >/dev/null 2>&1 && [ "${SKIP_CERT_CHECK:-}" != 1 ]; then
  openssl x509 -in "$ETC_DIR/pki/tls.crt" -noout -ext subjectAltName 2>/dev/null | grep -q "IP Address:$CERT_IP" \
    || die "tls.crt の SAN に $CERT_IP がありません"
fi
# サービスの実行ユーザー(etcd)で読めることを、登録の前に確認する(root では読めても、etcd では読めない場合がある)
if command -v runuser >/dev/null 2>&1 && [ "${SKIP_USER_CHECK:-}" != 1 ]; then
  for f in ca.crt tls.crt tls.key; do
    runuser -u etcd -- test -r "$ETC_DIR/pki/$f" || die "etcd ユーザーが $ETC_DIR/pki/$f を読めません(所有者・権限を確認)"
  done
else
  log "警告: runuser が無いので、etcd ユーザーで証明書を読めるかの確認を省略します"
fi

# --- 4. ユニットと環境ファイル -------------------------------------------------
changed=0
if ! cmp -s "$STAGE_DIR/karmada-etcd.service" "$UNIT_PATH" 2>/dev/null; then
  install -m 0644 "$STAGE_DIR/karmada-etcd.service" "$UNIT_PATH"
  changed=1
  "$SYSTEMCTL" daemon-reload
fi

env_file="$ETC_DIR/etcd.env"
# 参加済み(データがある)ときだけ、参加時に書かれた ETCD_INITIAL_CLUSTER を、再実行でも残す。
# 未参加なら、前回の失敗の残りを引き継がない(参加のときに、新しく書く)。
kept=""
if [ -d "$DATA_DIR/member" ] && [ -f "$env_file" ]; then
  kept=$(grep -E '^ETCD_INITIAL_CLUSTER=' "$env_file" || true)
fi
new_env=$(mktemp)
cat "$STAGE_DIR/etcd.env" > "$new_env"
if [ -n "$kept" ]; then printf '%s\n' "$kept" >> "$new_env"; fi
if ! cmp -s "$new_env" "$env_file" 2>/dev/null; then
  if [ "${ALLOW_NON_ROOT:-}" = 1 ]; then install -m 0640 "$new_env" "$env_file"; else install -m 0640 -o root -g etcd "$new_env" "$env_file"; fi
  changed=1
fi
rm -f "$new_env"

if [ "$JOIN" != 1 ]; then
  log "JOIN=0 なので、参加はしません(ユニット・環境ファイルとバイナリの用意だけ)"
  exit 0
fi

# --- 5. 参加 ------------------------------------------------------------------
member_started() {
  ctl member list -w simple 2>/dev/null | awk -F', ' -v n="$MEMBER_NAME" -v p="$PEER_URL" \
    '$3 == n && $4 == p && $2 == "started" { ok = 1 } END { exit !ok }'
}
local_ok() {
  "$ETCDCTL" --endpoints="$LOCAL_ENDPOINT" --cacert="$ETC_DIR/pki/ca.crt" --cert="$ETC_DIR/pki/tls.crt" --key="$ETC_DIR/pki/tls.key" \
    endpoint status >/dev/null 2>&1
}
# 一覧に started で載っているだけでは足りない(名前があれば started と出る)。このホストの etcd が、実際に応答することも見る
wait_ready() {
  local waited=0
  until member_started && local_ok; do
    [ "$waited" -ge "$WAIT_SECONDS" ] && return 1
    sleep 3
    waited=$((waited + 3))
  done
}

if [ -d "$DATA_DIR/member" ]; then
  log "すでに参加済みです(データがあります)"
  "$SYSTEMCTL" enable karmada-etcd
  if "$SYSTEMCTL" is-active karmada-etcd >/dev/null 2>&1; then
    if [ "$changed" = 1 ]; then log "設定が変わったので再起動します"; "$SYSTEMCTL" restart karmada-etcd; fi
  else
    "$SYSTEMCTL" start karmada-etcd
  fi
  wait_ready || die "etcd が $WAIT_SECONDS 秒以内に、準備できませんでした(データは残しています)"
  exit 0
fi

"$SYSTEMCTL" is-active karmada-etcd >/dev/null 2>&1 && die "データが無いのに etcd が起動しています"

list=$(ctl member list -w simple) || die "既存のメンバーに接続できません($SEED_ENDPOINTS)"
echo "$list"
echo "$list" | awk -F', ' '$2 == "started" && $6 == "false" { voter = 1 } END { exit !voter }' \
  || die "起動している voter が、クラスターにありません。参加させません"

# 同じ名前・同じ peer URL が、すでに登録されている場合
entry=$(own_entry || true)
if [ -n "$entry" ]; then
  stale_id=$(echo "$entry" | awk -F', ' 'NR == 1 && $2 == "unstarted" && $6 == "true" { print $1 }')
  if [ -n "$stale_id" ]; then
    # 前回の、登録だけで起動しなかった learner(自分の失敗の残り)。learner なので、安全に外せる
    log "前回の、起動していない learner($stale_id)を外してから、やり直します"
    ctl member remove "$stale_id" >/dev/null || die "古い登録(member $stale_id)を外せません。手動で: etcdctl member remove $stale_id"
  else
    die "メンバー $MEMBER_NAME(または $PEER_URL)は、すでに登録されていますが、ローカルにデータがありません(登録: $entry)。登録を外す(member remove)か、データを戻すこと"
  fi
fi

registered=0
succeeded=0
member_id=""

# 参加の途中で失敗したときは、登録(learner)を取り消してから、ローカルのデータを消す
cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$registered" = 1 ] && [ "$succeeded" = 0 ]; then
    log "参加に失敗したので、登録を取り消します(learner のため、安全)"
    "$SYSTEMCTL" stop karmada-etcd >/dev/null 2>&1 || true
    # 停止を確認できたときだけ、先へ進む。systemd との通信の失敗などで状態が分からないときは、止まっていると見なさない
    state=$("$SYSTEMCTL" is-active karmada-etcd 2>/dev/null || true)
    if [ "$state" != "inactive" ] && [ "$state" != "failed" ]; then
      echo "karmada-etcd-member: etcd の停止を確認できませんでした(状態: ${state:-不明})。データは消しません。手動で停止してから、etcdctl member remove ${member_id:-<ID>}" >&2
      exit "${rc:-1}"
    fi
    [ -n "$member_id" ] || member_id=$(own_entry 2>/dev/null | awk -F', ' 'NR == 1 { print $1 }') || true
    if [ -z "$member_id" ]; then
      echo "karmada-etcd-member: 登録の ID を特定できませんでした。データは消しません。etcdctl member list で確認してください" >&2
      exit "${rc:-1}"
    fi
    if ctl member remove "$member_id" >/dev/null 2>&1; then
      rm -rf "${DATA_DIR:?}/member"
      echo "karmada-etcd-member: 登録を取り消し、データを消しました(member $member_id)" >&2
    else
      echo "karmada-etcd-member: 登録を取り消せませんでした。データは消しません。手動で: etcdctl member remove $member_id" >&2
    fi
  fi
  exit "${rc:-1}"
}
trap cleanup EXIT

log "learner として登録します: $MEMBER_NAME ($PEER_URL)"
if ! out=$(ctl member add "$MEMBER_NAME" --learner --peer-urls="$PEER_URL" 2>&1); then
  echo "$out"
  # 応答だけが失われ、登録は済んでいることがある。登録されていれば、取り消す
  member_id=$(own_entry 2>/dev/null | awk -F', ' 'NR == 1 { print $1 }' || true)
  if [ -n "$member_id" ]; then registered=1; fi
  die "member add に失敗しました(learner の数の上限(--max-learners の既定は 1)を超えた可能性があります。クラスターの設定を確認すること)"
fi
echo "$out"
registered=1
# 出力の ID は、空白が付くことがあるので、一覧から取る(peer URL で特定する)
member_id=$(own_entry | awk -F', ' 'NR == 1 { print $1 }' || true)
cluster_line=$(echo "$out" | grep -E '^ETCD_INITIAL_CLUSTER=' | head -1 || true)
[ -n "$cluster_line" ] || die "member add の出力に ETCD_INITIAL_CLUSTER がありません"

printf '%s\n' "$cluster_line" >> "$env_file"
"$SYSTEMCTL" enable --now karmada-etcd || die "etcd を起動できませんでした"
wait_ready || die "$WAIT_SECONDS 秒以内に、メンバーが準備できませんでした"

succeeded=1
log "learner として参加しました(promote は、別の判断で手動)"
ctl member list -w simple
