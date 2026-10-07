#!/usr/bin/env bash
# ローカルの kube-apiserver が応答しないとき、このノードの kube-vip を一時的に止める (issue #232)。
#
# kube-vip のリーダーのノードで、OS と BGP デーモンは生きているが kube-apiserver だけがハングすると、
# VIP を持ち続け、BGP の経路が撤回されず、API への通信が壊れたノードに流れ続ける。
# このスクリプトは systemd timer から数秒おきに呼ばれ、ローカルの apiserver の /livez を確認する。
#   - 連続 FAIL_THRESHOLD 回失敗: kube-vip の static pod のマニフェストを退避し(kubelet が pod を止める)、
#     VIP のアドレスが残っていれば外す。リースは手放されるので、別のノードが VIP を引き継ぐ。
#   - 退避中に連続 OK_THRESHOLD 回成功: マニフェストを戻す。
#
# 全ノードが一斉に kube-vip を止めて、VIP の持ち主がいなくなる事態を避けるため、止める前に、
# PEERS(他の control-plane の apiserver)の /livez を確認し、健全なものが 1 つも無ければ止めない。
# /livez?exclude=etcd を使うのは、etcd の quorum を失ったときに、全ノードの apiserver が
# etcd のせいで失敗しても、一律には止めないため(上の PEERS の確認と二重の安全策)。
# ENABLED が true でないとき(Terraform が kube-vip を意図的に外したノード)は、何もしない。
# このスクリプト自体は、OS 全体が止まったときには動かない。その場合は BGP の hold timer が頼り。
set -u

[ "${ENABLED:-true}" = "true" ] || exit 0

STATE_DIR="${STATE_DIR:-/var/lib/kube-vip-health}"
PEERS="${PEERS:-}"
MANIFEST="${MANIFEST:-/etc/kubernetes/manifests/kube-vip.yaml}"
VIP="${VIP:?VIP is required}"
IFACE="${IFACE:-ens18}"
API_PORT="${API_PORT:-6443}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
OK_THRESHOLD="${OK_THRESHOLD:-6}"
CURL_BIN="${CURL_BIN:-curl}"
IP_BIN="${IP_BIN:-ip}"
LOGGER_BIN="${LOGGER_BIN:-logger}"

PARKED="$STATE_DIR/kube-vip.yaml"
FAILS_FILE="$STATE_DIR/fails"
OKS_FILE="$STATE_DIR/oks"

log() { "$LOGGER_BIN" -t kube-vip-health -- "$*" 2>/dev/null || echo "kube-vip-health: $*" >&2; }

mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || exit 0

read_count() { cat "$1" 2>/dev/null || echo 0; }

# 他の control-plane の apiserver が、1 つでも健全なら 0
any_peer_healthy() {
  local peer
  for peer in $PEERS; do
    [ "$("$CURL_BIN" -sk --max-time 3 -o /dev/null -w '%{http_code}' \
      "https://${peer}:${API_PORT}/livez?exclude=etcd" 2>/dev/null || true)" = "200" ] && return 0
  done
  return 1
}

code=$("$CURL_BIN" -sk --max-time 3 -o /dev/null -w '%{http_code}' \
  "https://127.0.0.1:${API_PORT}/livez?exclude=etcd" 2>/dev/null || true)
if [ "$code" = "200" ]; then healthy=true; else healthy=false; fi

if [ -f "$PARKED" ] && [ ! -f "$MANIFEST" ]; then
  # 退避中: VIP が残っていれば外し、回復を数える
  if "$IP_BIN" -4 addr show dev "$IFACE" 2>/dev/null | grep -qE "inet ${VIP//./\\.}/32"; then
    "$IP_BIN" addr del "${VIP}/32" dev "$IFACE" 2>/dev/null && log "removed leftover VIP ${VIP} from ${IFACE}"
  fi
  if $healthy; then
    oks=$(( $(read_count "$OKS_FILE") + 1 ))
    echo "$oks" > "$OKS_FILE"
    if [ "$oks" -ge "$OK_THRESHOLD" ]; then
      mv "$PARKED" "$MANIFEST"
      rm -f "$FAILS_FILE" "$OKS_FILE"
      log "local apiserver healthy for ${oks} checks; restored kube-vip manifest"
    fi
  else
    echo 0 > "$OKS_FILE"
  fi
  exit 0
fi

# 稼働中 (マニフェストが有効)。マニフェストが無い (enabled=false 等) ときは何もしない。
[ -f "$MANIFEST" ] || exit 0
if $healthy; then
  rm -f "$FAILS_FILE"
  exit 0
fi

fails=$(( $(read_count "$FAILS_FILE") + 1 ))
echo "$fails" > "$FAILS_FILE"
log "local apiserver /livez failed (code=${code:-none}) ${fails}/${FAIL_THRESHOLD}"
if [ "$fails" -ge "$FAIL_THRESHOLD" ]; then
  if ! any_peer_healthy; then
    log "no healthy peer apiserver (PEERS='${PEERS}'); keeping kube-vip so the VIP is not left without an owner"
    exit 0
  fi
  mv "$MANIFEST" "$PARKED"
  rm -f "$FAILS_FILE"
  echo 0 > "$OKS_FILE"
  log "parked kube-vip manifest; VIP ${VIP} should move to another control-plane node"
fi
exit 0
