#!/bin/bash
# Karmada の control plane(IONOS = CP #3)を、冪等に構成し、stage に応じて起動する(kigawa-net/kigawa-net-k8s#268)。
#
# やること:
#   1. karmada ユーザーとディレクトリを用意する
#   2. バイナリを、SHA256 を照合したうえで配置する(url から、または image から crane で取り出す)
#   3. ユニット・slice・kubeconfig・REDIRECT の表・/etc/hosts のブロックを、Terraform の内容に揃える
#   4. REDIRECT(`*.karmada-system.svc` → ローカルの各サービス)を有効にする(inert。何も起動しない)
#   5. ufw: kube-apiserver(5443)を、WireGuard 内の指定の送信元にだけ許可する
#   6. stage に応じて、起動する(prepare = 何も起動せず、起動中のものは止める = ロールバック)
#
# 守ること:
#   - ゲートウェイ(WireGuard / FRR / HAProxy)と etcd には、一切、触れない(systemctl の対象は karmada-* のユニットだけ)
#   - 証明書と秘密鍵は、この IaC の外で用意されたものを使う(内容は、扱わない)。起動の前に、鍵と証明書の対、CA での検証、期限、
#     karmada.key の指紋を確認する
#   - 起動の前にメモリを確認し、足りなければ、起動せずに中止する
#   - 起動に失敗したら、CP のサービスを、すべて止める(prepare に戻す)
set -euo pipefail

: "${STAGE:?}" "${STAGE_DIR:?}" "${ALL_UNITS:?}" "${ADVERTISE:?}"
START_UNITS="${START_UNITS:-}"
MIN_MEM_MB="${MIN_MEM_MB:-700}"
MIN_AFTER_MB="${MIN_AFTER_MB:-250}"
API_SOURCES="${API_SOURCES:-}"
WG_IF="${WG_IF:-wg0}"
KARMADA_KEY_FPR="${KARMADA_KEY_FPR:-}"
WAIT_SECONDS="${WAIT_SECONDS:-120}"

ETC="${ETC_DIR:-/etc/karmada}"
PKI="$ETC/pki"
WHK="$ETC/webhook-cert"
SBIN="${SBIN_DIR:-/usr/local/sbin}"
BINDIR="${BIN_DIR:-/usr/local/bin}"
SYSD="${SYSTEMD_DIR:-/etc/systemd/system}"
HOSTS="${HOSTS_FILE:-/etc/hosts}"
MEMINFO="${MEMINFO:-/proc/meminfo}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
CURL="${CURL:-curl}"
UFW="${UFW:-ufw}"
JOURNALCTL="${JOURNALCTL:-journalctl}"

log() { echo "karmada-cp-member: $*"; }
die() { echo "karmada-cp-member: ABORT: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || [ "${ALLOW_NON_ROOT:-}" = 1 ] || die "root で実行すること(ssh_user = root)"
case "$STAGE" in prepare | apiserver | full) ;; *) die "STAGE が不正です: $STAGE" ;; esac
for f in bundle.txt binaries.txt crane.txt karmada-cp-redirect.sh; do
  [ -s "$STAGE_DIR/$f" ] || die "$STAGE_DIR/$f がありません"
done

# --- 0. 入力の検証(シェルに渡す前に、形を確認する) ---------------------------------
[[ "$ADVERTISE" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "ADVERTISE が不正です: $ADVERTISE"
[[ "$WG_IF" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || die "WG_IF が不正です: $WG_IF"
[[ "$MIN_MEM_MB" =~ ^[0-9]+$ && "$MIN_AFTER_MB" =~ ^[0-9]+$ && "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || die "数値の設定が不正です"
[[ "$KARMADA_KEY_FPR" =~ ^([0-9a-f]{64})?$ ]] || die "KARMADA_KEY_FPR が不正です"
for u in $ALL_UNITS $START_UNITS; do
  [[ "$u" =~ ^karmada-[a-z-]+$ ]] || die "ユニット名が不正です: $u"
done
IFS=',' read -ra _srcs <<< "$API_SOURCES"
for s in "${_srcs[@]}"; do
  [ -z "$s" ] && continue
  [[ "$s" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "api_allowed_sources が不正です: $s"
done

ALL_REV=""
for u in $ALL_UNITS; do ALL_REV="$u $ALL_REV"; done # 依存する側を先に止める

# `is-active` は、再起動待ち(activating (auto-restart))の状態では失敗を返す。クラッシュを繰り返すサービスを、止め損ねないよう、
# 状態に関わらず、無条件に stop する(stop は、冪等。止まっているユニットにも、成功する)
stop_all() {
  local u
  for u in $ALL_REV; do
    "$SYSTEMCTL" stop "$u.service" >/dev/null 2>&1 || true
  done
}
disable_all() {
  local u
  for u in $ALL_REV; do
    if "$SYSTEMCTL" is-enabled --quiet "$u.service" 2>/dev/null; then "$SYSTEMCTL" disable "$u.service" >/dev/null 2>&1 || true; fi
  done
}
# prepare は、取得や配置など、失敗しうる作業より前に、CP のサービスを止める(途中で失敗しても、止まった状態を保証する)
if [ "$STAGE" = prepare ]; then
  stop_all
  disable_all
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 所有者の指定は、root のときだけ(テストでは、外す)
own() { # $1=owner:group $2..=パス
  [ "${ALLOW_NON_ROOT:-}" = 1 ] && return 0
  local o=$1; shift; chown "$o" "$@"
}
mkdir_own() { install -d -m "$1" "${@:3}"; own "$2" "${@:3}"; }

# --- 1. ユーザーとディレクトリ -------------------------------------------------
id karmada >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin karmada
mkdir_own 0750 root:karmada "$ETC" "$PKI" "$ETC/config" "$WHK"

# --- 2. バイナリ -------------------------------------------------------------
sha_of() { sha256sum "$1" | cut -d' ' -f1; }

ensure_crane() {
  local url sha marker="$BINDIR/.crane.tarball.sha256"
  IFS='|' read -r url sha < "$STAGE_DIR/crane.txt"
  [ -x "$BINDIR/crane" ] && [ -f "$marker" ] && [ "$(cat "$marker")" = "$sha" ] && return 0
  log "crane を入れます"
  "$CURL" -fsSL --connect-timeout 15 --max-time 300 -o "$WORK/crane.tgz" "$url"
  [ "$(sha_of "$WORK/crane.tgz")" = "$sha" ] || die "crane の tarball の SHA256 が一致しません"
  tar xzf "$WORK/crane.tgz" -C "$WORK" crane
  install -m 0755 "$WORK/crane" "$BINDIR/crane"
  echo "$sha" > "$marker"
}

BIN_CHANGED=0
install_binary() { # name|source|ref|path|sha256
  local name=$1 source=$2 ref=$3 path=$4 sha=$5 dest="$SBIN/$1" tmp
  [[ "$name" =~ ^(kube|karmada)-[a-z-]+$ ]] || die "バイナリ名が不正です: $name"
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "$name の sha256 が不正です"
  case "$source" in image) [[ "$path" =~ ^[A-Za-z0-9._/-]+$ && "$path" != /* && "$path" != *..* ]] || die "$name の path が不正です: $path" ;; esac
  if [ -x "$dest" ] && [ "$(sha_of "$dest")" = "$sha" ]; then
    log "$name は、すでに入っています(SHA256 一致)"
    return 0
  fi
  tmp=$(mktemp -p "$WORK")
  case "$source" in
    url) "$CURL" -fsSL --connect-timeout 15 --max-time 600 -o "$tmp" "$ref" || die "$name の取得に失敗しました" ;;
    image)
      ensure_crane
      "$BINDIR/crane" export "$ref" - | tar -xO "$path" > "$tmp" || die "$name を image から取り出せませんでした"
      ;;
    *) die "$name の source が不正です: $source" ;;
  esac
  [ "$(sha_of "$tmp")" = "$sha" ] || die "$name の SHA256 が一致しません(配置しません)。期待: $sha"
  install -m 0755 "$tmp" "$dest.new"
  mv -f "$dest.new" "$dest" # 置き換えは、原子的に(起動中でも、安全)
  BIN_CHANGED=1
  log "$name を配置しました"
}

install -d -m 0755 "$SBIN" "$BINDIR"

# ダウンロードが要るときだけ、ディスクの空きを確認する(約 700MB)
need_dl=0
while IFS='|' read -r name source ref path sha; do
  [ -z "${name:-}" ] && continue
  if ! { [ -x "$SBIN/$name" ] && [ "$(sha_of "$SBIN/$name")" = "$sha" ]; }; then need_dl=1; fi
done < "$STAGE_DIR/binaries.txt"
if [ "$need_dl" = 1 ]; then
  free_kb=$(df -Pk "$SBIN" | awk 'NR==2 {print $4}')
  [ "${free_kb:-0}" -ge 2097152 ] || die "ディスクの空きが足りません(2GB 未満): ${free_kb} KB"
fi
while IFS='|' read -r name source ref path sha; do
  [ -z "${name:-}" ] && continue
  install_binary "$name" "$source" "$ref" "$path" "$sha"
done < "$STAGE_DIR/binaries.txt"

# --- 3. bundle(ユニット・slice・kubeconfig・表) --------------------------------
# bundle の中身は、パスを許可リストで検証してから、置く(Terraform の誤りで、想定外の場所に書かないため)
ALLOWED_RE='^(/etc/systemd/system/karmada-[a-z-]+\.(service|slice)|/etc/karmada/(hosts\.block|redirect\.table|config/karmada\.config))$'
awk -v dir="$WORK/bundle" '
  BEGIN { n = 0; system("mkdir -p " dir) }
  /^@@@ / { n++; f = sprintf("%s/%03d", dir, n); print $2 " " $3 > (dir "/index"); next }
  { if (n > 0) print > f }
' "$STAGE_DIR/bundle.txt"
[ -f "$WORK/bundle/index" ] || die "bundle が空です"

map_path() { # /etc/systemd/system/x -> $SYSD/x、/etc/karmada/x -> $ETC/x
  case "$1" in
    /etc/systemd/system/*) echo "$SYSD/${1#/etc/systemd/system/}" ;;
    /etc/karmada/*) echo "$ETC/${1#/etc/karmada/}" ;;
  esac
}

SYSTEMD_CHANGED=0
UNIT_CHANGED=""   # 内容が変わったユニット(起動中なら、再起動する)
i=0
while read -r path mode; do
  i=$((i + 1))
  [[ "$path" =~ $ALLOWED_RE ]] || die "bundle に、許可されていないパスがあります: $path"
  [[ "$mode" =~ ^0[0-7]{3}$ ]] || die "bundle のモードが不正です: $mode"
  src=$(printf '%s/bundle/%03d' "$WORK" "$i")
  dst=$(map_path "$path")
  if ! cmp -s "$src" "$dst" 2>/dev/null; then
    install -d "$(dirname "$dst")"
    install -m "$mode" "$src" "$dst"
    case "$path" in
      /etc/systemd/system/*)
        SYSTEMD_CHANGED=1
        UNIT_CHANGED="$UNIT_CHANGED $(basename "$dst" .service)"
        ;;
    esac
    log "更新しました: $path"
  fi
  case "$path" in */karmada.config) own root:karmada "$dst"; chmod 0640 "$dst" ;; esac
done < "$WORK/bundle/index"

install -m 0755 "$STAGE_DIR/karmada-cp-redirect.sh" "$SBIN/karmada-cp-redirect.sh.new"
if ! cmp -s "$SBIN/karmada-cp-redirect.sh.new" "$SBIN/karmada-cp-redirect.sh" 2>/dev/null; then
  mv -f "$SBIN/karmada-cp-redirect.sh.new" "$SBIN/karmada-cp-redirect.sh"
else
  rm -f "$SBIN/karmada-cp-redirect.sh.new"
fi
[ "$SYSTEMD_CHANGED" = 1 ] && "$SYSTEMCTL" daemon-reload

# --- 4. /etc/hosts のブロック(管理するブロックだけを置き換える) ---------------------
BEGIN_MARK="# BEGIN karmada-cp (managed by terraform: hardware/modules/karmada-cp-member)"
END_MARK="# END karmada-cp"
strip_block() { awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip { print }' "$1"; }
[ -s "$ETC/hosts.block" ] || die "$ETC/hosts.block がありません"
nb=$(grep -cxF "$BEGIN_MARK" "$HOSTS" || true); ne=$(grep -cxF "$END_MARK" "$HOSTS" || true)
[ "$nb" = "$ne" ] && [ "$nb" -le 1 ] || die "/etc/hosts のマーカーが壊れています(BEGIN=$nb, END=$ne)。手で直してください(書きません)"
{ strip_block "$HOSTS"; echo "$BEGIN_MARK"; cat "$ETC/hosts.block"; echo "$END_MARK"; } > "$WORK/hosts.new"
if ! cmp -s "$WORK/hosts.new" "$HOSTS"; then
  [ -e "$HOSTS.bak-karmada-cp" ] || cp -p "$HOSTS" "$HOSTS.bak-karmada-cp"
  # ブロックの外が、変わっていないことを確認してから、書く
  [ "$(strip_block "$WORK/hosts.new")" = "$(strip_block "$HOSTS")" ] || die "/etc/hosts のブロックの外が、変わってしまいます(書きません)"
  # 同じディレクトリに書いてから、原子的に置き換える(途中で切れて、/etc/hosts が壊れることを避ける)
  cp -p "$HOSTS" "$HOSTS.karmada-cp.new"
  cat "$WORK/hosts.new" > "$HOSTS.karmada-cp.new"
  mv -f "$HOSTS.karmada-cp.new" "$HOSTS"
  log "/etc/hosts のブロックを更新しました"
fi

# --- 5. REDIRECT(inert。何も起動しない) -------------------------------------------
"$SYSTEMCTL" enable --now karmada-cp-redirect.service
# ユニットは RemainAfterExit なので、表が変わっても、再実行されない。冪等な start を直接実行して、ルールを表に揃える
"$SBIN/karmada-cp-redirect.sh" start
"$SBIN/karmada-cp-redirect.sh" status || die "REDIRECT のルールが揃っていません"

# --- 6. ufw: kube-apiserver(5443)を、WireGuard 内の指定の送信元にだけ許可 ----------------
if command -v "$UFW" >/dev/null 2>&1 || [ -x "$UFW" ]; then
  IFS=',' read -ra srcs <<< "$API_SOURCES"
  for s in "${srcs[@]}"; do
    [ -z "$s" ] && continue
    "$UFW" allow in on "$WG_IF" from "$s" to any port 5443 proto tcp >/dev/null
  done
else
  log "警告: ufw が無いので、5443 の許可は設定しません"
fi

# --- 7. stage -----------------------------------------------------------------
fail_and_rollback() { # $1=ユニット $2=理由
  log "失敗: $1: $2。CP のサービスを、すべて止めます(prepare に戻します)"
  "$JOURNALCTL" -u "$1.service" -n 25 --no-pager 2>/dev/null | sed 's/^/    | /' || true
  stop_all
  disable_all
  die "$1 を起動できませんでした: $2"
}
mem_available_mb() { awk '/^MemAvailable:/ {print int($2 / 1024)}' "$MEMINFO"; }

if [ "$STAGE" = prepare ]; then
  log "stage=prepare: 何も起動していません(起動中だった CP のサービスは、止めました)"
  exit 0
fi

# 起動の前の確認 ------------------------------------------------------------------
missing=()
need() { for f in "$@"; do [ -s "$f" ] || missing+=("$f"); done; }
need "$PKI/ca.crt" "$PKI/front-proxy-ca.crt" "$PKI/etcd-ca.crt" \
  "$PKI/apiserver.crt" "$PKI/apiserver.key" "$PKI/front-proxy-client.crt" "$PKI/front-proxy-client.key" \
  "$PKI/etcd-client.crt" "$PKI/etcd-client.key" "$PKI/karmada.key"
if [ "$STAGE" = full ]; then
  need "$PKI/ionos-karmada-cp.crt" "$PKI/ionos-karmada-cp.key" "$PKI/aggregated-apiserver.crt" "$PKI/aggregated-apiserver.key" \
    "$PKI/metrics-adapter.crt" "$PKI/metrics-adapter.key" "$WHK/tls.crt" "$WHK/tls.key"
fi
if [ "${#missing[@]}" -gt 0 ]; then
  printf 'karmada-cp-member: 足りないファイル:\n' >&2
  printf '  %s\n' "${missing[@]}" >&2
  die "証明書・鍵が揃っていないので、起動しません(stage=$STAGE。これらは、この IaC の外で用意する)"
fi

pub_of_cert() { openssl x509 -in "$1" -noout -pubkey; }
pub_of_key() { openssl pkey -in "$1" -pubout; }
check_pair() { # $1=証明書 $2=鍵 $3=CA $4=用途
  [ "$(pub_of_cert "$1")" = "$(pub_of_key "$2")" ] || die "鍵と証明書が対になっていません: $1 / $2"
  openssl verify -CAfile "$3" -purpose "$4" "$1" >/dev/null 2>&1 || die "CA で検証できません: $1($3、$4)"
  openssl x509 -in "$1" -noout -checkend 0 >/dev/null 2>&1 || die "期限切れです: $1"
  openssl x509 -in "$1" -noout -checkend 2592000 >/dev/null 2>&1 || log "警告: 30 日以内に期限が切れます: $1"
}
check_pair "$PKI/apiserver.crt" "$PKI/apiserver.key" "$PKI/ca.crt" sslserver
openssl x509 -in "$PKI/apiserver.crt" -noout -ext subjectAltName 2>/dev/null | grep -q "IP Address:$ADVERTISE" \
  || die "apiserver.crt の SAN に $ADVERTISE がありません"
check_pair "$PKI/front-proxy-client.crt" "$PKI/front-proxy-client.key" "$PKI/front-proxy-ca.crt" sslclient
check_pair "$PKI/etcd-client.crt" "$PKI/etcd-client.key" "$PKI/etcd-ca.crt" sslclient
if [ -n "$KARMADA_KEY_FPR" ]; then
  fpr=$(openssl pkey -in "$PKI/karmada.key" -pubout -outform der | sha256sum | cut -d' ' -f1)
  [ "$fpr" = "$KARMADA_KEY_FPR" ] || die "karmada.key の指紋が、期待した値と違います(転送の途中で、壊れた、または、すり替わった可能性があります)"
fi
if [ "$STAGE" = full ]; then
  check_pair "$PKI/ionos-karmada-cp.crt" "$PKI/ionos-karmada-cp.key" "$PKI/ca.crt" sslclient
  check_pair "$PKI/aggregated-apiserver.crt" "$PKI/aggregated-apiserver.key" "$PKI/ca.crt" sslserver
  check_pair "$PKI/metrics-adapter.crt" "$PKI/metrics-adapter.key" "$PKI/ca.crt" sslserver
  check_pair "$WHK/tls.crt" "$WHK/tls.key" "$PKI/ca.crt" sslserver
fi
# 鍵を、サービスの実行ユーザーが読めるようにする(root:karmada、0640)
for k in "$PKI"/*.key "$WHK"/tls.key; do
  [ -f "$k" ] && [ ! -L "$k" ] && { own root:karmada "$k"; chmod 0640 "$k"; }
done
for c in "$PKI"/*.crt "$WHK"/tls.crt; do
  [ -f "$c" ] && [ ! -L "$c" ] && { own root:karmada "$c"; chmod 0644 "$c"; }
done

avail=$(mem_available_mb)
[ "${avail:-0}" -ge "$MIN_MEM_MB" ] || die "MemAvailable が足りません(${avail}MB < ${MIN_MEM_MB}MB)。ゲートウェイを守るため、起動しません"
log "起動の前の確認: 鍵と証明書の対、CA での検証、期限、SAN、メモリ(${avail}MB)すべて OK"

# 起動 -----------------------------------------------------------------------------
wait_readyz() {
  local waited=0
  until "$CURL" -fsS -m 5 --cacert "$PKI/ca.crt" "https://$ADVERTISE:5443/readyz" >/dev/null 2>&1; do
    [ "$waited" -ge "$WAIT_SECONDS" ] && return 1
    sleep 3
    waited=$((waited + 3))
  done
}
start_unit() {
  local u=$1
  if "$SYSTEMCTL" is-active --quiet "$u.service" 2>/dev/null && { [ "$BIN_CHANGED" = 1 ] || echo "$UNIT_CHANGED" | grep -qw "$u"; }; then
    log "$u: バイナリまたはユニットが変わったので、再起動します"
    "$SYSTEMCTL" restart "$u.service" || fail_and_rollback "$u" "再起動に失敗"
  else
    "$SYSTEMCTL" enable --now "$u.service" >/dev/null 2>&1 || fail_and_rollback "$u" "起動に失敗"
  fi
}

# 起動を許されていないものは、止めて、無効にする(stage を下げたとき)
for u in $ALL_UNITS; do
  case " $START_UNITS " in *" $u "*) ;; *)
    "$SYSTEMCTL" stop "$u.service" >/dev/null 2>&1 || true
    "$SYSTEMCTL" is-enabled --quiet "$u.service" 2>/dev/null && "$SYSTEMCTL" disable "$u.service" >/dev/null 2>&1 || true
  ;; esac
done

start_unit karmada-apiserver
wait_readyz || fail_and_rollback karmada-apiserver "${WAIT_SECONDS} 秒以内に /readyz が通りませんでした(etcd への接続・証明書を確認)"
log "karmada-apiserver: /readyz OK"

for u in $START_UNITS; do
  [ "$u" = karmada-apiserver ] && continue
  start_unit "$u"
  sleep "${SETTLE_SECONDS:-5}"
  "$SYSTEMCTL" is-active --quiet "$u.service" || fail_and_rollback "$u" "起動直後に、active でなくなりました"
  sleep "${SETTLE_SECONDS:-5}"
  "$SYSTEMCTL" is-active --quiet "$u.service" || fail_and_rollback "$u" "起動して、しばらくあとに、active でなくなりました(再起動の繰り返し)"
  log "$u: active"
done

avail=$(mem_available_mb)
log "起動後の MemAvailable: ${avail}MB"
if [ "${avail:-0}" -lt "$MIN_AFTER_MB" ]; then
  fail_and_rollback karmada-apiserver "起動後の MemAvailable が少なすぎます(${avail}MB < ${MIN_AFTER_MB}MB)。ゲートウェイを守るため、止めます"
fi
log "stage=$STAGE: 完了"
