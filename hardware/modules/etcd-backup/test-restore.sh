#!/usr/bin/env bash
# etcd のスナップショットを、隔離した docker の etcd に restore して、データが読めることを確認する (issue #189)。
# 本番には触れない。復旧手順(docs/etcd-backup-restore.md)の確認と、定期的な restore テストに使う。
#
# 使い方:
#   bash test-restore.sh --selftest            # 手順の確認用に、自前のスナップショットを作って restore する
#   bash test-restore.sh <snapshot.db[.gz]>    # 本番から取って復号したスナップショットを restore する
#                                              #   (復号は docs/etcd-backup-restore.md の手順で、手元の秘密鍵を使う)
# 要: docker と gcr.io/etcd-development/etcd:v3.5.16(etcdctl / etcdutl を含む)
set -u

IMG="${ETCD_IMAGE:-gcr.io/etcd-development/etcd:v3.5.16}"
# ほかの実行や、同名のコンテナを巻き込まないよう、PID で一意にする
NAME="etcd-restore-test-$$"
work=$(mktemp -d)
cleanup() { docker rm -f "$NAME" "$NAME-seed" >/dev/null 2>&1; rm -rf "$work"; }
# docker(既定は root)が作ったファイルは、一般ユーザーでは消せない。自分の UID で動かして、避ける。
U=(--user "$(id -u):$(id -g)")
trap cleanup EXIT

fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected=$2 actual=$3)"; fails=$((fails + 1)); fi; }
ectl() { docker exec "$NAME" etcdctl --endpoints=http://127.0.0.1:2379 "$@"; }

snapshot=""
expect_keys=""
if [ "${1:-}" = "--selftest" ]; then
  echo "== 自前のスナップショットを作る(Kubernetes の /registry/ に似たキーを入れる)"
  docker run -d "${U[@]}" --name "$NAME-seed" -v "$work:/out" "$IMG" etcd \
    --data-dir=/tmp/seed --listen-client-urls=http://0.0.0.0:2379 --advertise-client-urls=http://127.0.0.1:2379 >/dev/null
  for i in $(seq 1 30); do docker exec "$NAME-seed" etcdctl --endpoints=http://127.0.0.1:2379 endpoint health >/dev/null 2>&1 && break; sleep 1; done
  for ns in default kube-system rook-ceph; do
    docker exec "$NAME-seed" etcdctl --endpoints=http://127.0.0.1:2379 put "/registry/namespaces/$ns" "ns-$ns" >/dev/null
  done
  for i in $(seq 1 200); do
    docker exec "$NAME-seed" etcdctl --endpoints=http://127.0.0.1:2379 put "/registry/secrets/default/s$i" "v$i" >/dev/null
  done
  docker exec "$NAME-seed" etcdctl --endpoints=http://127.0.0.1:2379 snapshot save /out/seed.db >/dev/null
  snapshot="$work/seed.db"
  expect_keys=203
  docker rm -f "$NAME-seed" >/dev/null
else
  snapshot="${1:?usage: test-restore.sh --selftest | <snapshot.db[.gz]>}"
  case "$snapshot" in *.gz) gunzip -c "$snapshot" > "$work/snap.db"; snapshot="$work/snap.db" ;; esac
  [ -s "$snapshot" ] || { echo "snapshot not found or empty: $snapshot" >&2; exit 2; }
fi

echo "== スナップショットの整合性(etcdutl snapshot status)"
docker run --rm "${U[@]}" -v "$(dirname "$snapshot"):/in:ro" "$IMG" etcdutl snapshot status "/in/$(basename "$snapshot")" -w table || fails=$((fails + 1))

echo "== restore(etcdutl snapshot restore)して、1 台の etcd として起動する"
docker run --rm "${U[@]}" -v "$(dirname "$snapshot"):/in:ro" -v "$work:/restore" "$IMG" \
  etcdutl snapshot restore "/in/$(basename "$snapshot")" --data-dir=/restore/data \
  --bump-revision 1000000000 --mark-compacted \
  --name restored --initial-cluster restored=http://127.0.0.1:2380 --initial-advertise-peer-urls http://127.0.0.1:2380 >/dev/null 2>&1 \
  || { echo "FAIL - restore failed"; exit 1; }
docker run -d "${U[@]}" --name "$NAME" -v "$work/data:/data" "$IMG" etcd --name restored --data-dir=/data \
  --listen-client-urls=http://0.0.0.0:2379 --advertise-client-urls=http://127.0.0.1:2379 \
  --listen-peer-urls=http://0.0.0.0:2380 --initial-advertise-peer-urls=http://127.0.0.1:2380 \
  --initial-cluster restored=http://127.0.0.1:2380 >/dev/null
healthy=no
for i in $(seq 1 60); do ectl endpoint health >/dev/null 2>&1 && { healthy=yes; break; }; sleep 1; done
check "restored etcd becomes healthy" yes "$healthy"

keys=$(ectl get /registry/ --prefix --keys-only 2>/dev/null | grep -c '^/registry/')
echo "復元されたキー数: $keys"
check "restored data has /registry/ keys" yes "$([ "${keys:-0}" -gt 0 ] && echo yes || echo no)"
if [ -n "$expect_keys" ]; then
  check "selftest: all $expect_keys keys restored" "$expect_keys" "$keys"
  check "selftest: namespace kube-system readable" "ns-kube-system" "$(ectl get /registry/namespaces/kube-system --print-value-only 2>/dev/null)"
else
  check "kube-system namespace exists" yes "$([ "$(ectl get /registry/namespaces/kube-system --keys-only 2>/dev/null | grep -c '^/registry/namespaces/kube-system')" -ge 1 ] && echo yes || echo no)"
fi
# Kubernetes の controller / apiserver の watch は、リビジョンを覚えている。restore で、リビジョンが巻き戻ると、
# 生き残った controller が、古い cache のまま watch を続けてしまう。--bump-revision で、必ず先へ進める。
rev=$(ectl endpoint status -w json 2>/dev/null | grep -o '"revision":[0-9]*' | head -1 | cut -d: -f2)
echo "restore 後のリビジョン: ${rev:-?}"
check "revision was bumped (>= 1e9) so old watchers must resync" yes "$([ "${rev:-0}" -ge 1000000000 ] && echo yes || echo no)"
check "restored etcd accepts writes" OK "$(ectl put /restore-test/ok 1 2>/dev/null)"

if [ "$fails" -eq 0 ]; then echo "all restore checks passed"; else echo "$fails check(s) failed"; exit 1; fi
