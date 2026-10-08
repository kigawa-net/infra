# etcd のバックアップと復旧手順

issue #189。control-plane は 3 台で冗長化されているが、冗長化は、誤操作・論理破損・複数ノードの同時喪失(2026-10-07 に、k8s1 のハングと k8s2 のダウンが重なった)に対するバックアップにはならない。

## 目標値

| 項目 | 目標 | 根拠 |
|---|---|---|
| **RPO**(失ってよいデータの時間) | **1 時間** | スナップショットを 1 時間おきに取る |
| **RTO**(復旧までの時間) | **2 時間** | 下の「全体の復旧」の手順(スナップショットの取得・復号・3 台への restore・kubeadm の確認) |

## 仕組み

- `hardware/modules/etcd-backup`(現在は k8s2 だけ)。systemd timer(`etcd-backup.timer`、60 分間隔)が `etcd-backup.sh` を動かす。
  1. ディスクの空きを確認(足りなければ、何も作らず失敗する)。
  2. etcd のコンテナの `etcdctl snapshot save` で取り、`etcdctl snapshot status` で整合性を確認する。
  3. `gzip` → `age`(公開鍵)で暗号化して、R2 のバケット `etcd-backup` に置く。`/etc/kubernetes/pki` と `admin.conf`(control-plane の再構築に必要)も、別のファイルとして、同じ形で置く。
  4. アップロードしたサイズを HEAD で確認する。
  5. 保持期間(14 日)を過ぎた古い世代を削除する。ただし、最新の 48 世代は、必ず残す。一覧が不完全なら、削除しない。
  6. 結果を node_exporter の textfile(`etcd_backup_*`)に書く。
- 保存先のキー: `k8s2/<UTC のタイムスタンプ>/{etcd-snapshot.db.gz.age, pki.tar.gz.age, snapshot-status.json.age}`。
- **暗号化は公開鍵だけ**。ノードには公開鍵(`/etc/etcd-backup/env` の `AGE_RECIPIENT`)しか無く、**復号の秘密鍵は Bitwarden に保管する**(ノードや R2 が侵害されても、過去のバックアップは読めない)。スナップショットには、全ての Secret が入っているので、秘密鍵の扱いに注意する。
- R2 のトークンは、`etcd-backup` バケット限定(Object Read & Write)。

## 有効化の手順(初回)

1. Cloudflare のダッシュボードで、`etcd-backup` バケット限定の R2 トークン(Object Read & Write)を作り、アクセスキー ID とシークレットを、Bitwarden Secrets に登録する。
2. `age-keygen -o etcd-backup.key` で鍵ペアを作る。**秘密鍵(`etcd-backup.key`)を Bitwarden に保管し、手元のファイルは消す**。公開鍵(`age1...`)だけを、次で使う。
3. `hardware/k8s2/variables.tf` の既定値を変える PR を出す(マージで GitHub Actions が apply する):
   - `etcd_backup_enabled = true`
   - `etcd_backup_age_recipient = "age1..."`
   - `etcd_backup_r2_access_key_bitwarden_id` / `etcd_backup_r2_secret_bitwarden_id` = 手順 1 の UUID
4. 適用の 2 分後に、初回が動く。次で確認する。

```bash
# k8s2 で
systemctl list-timers etcd-backup.timer
journalctl -t etcd-backup --since "-30min"
cat /var/lib/node_exporter/textfile/etcd_backup.prom
```

## 取り出し・復号

R2 のバケットから、目的の世代を取る(`aws` CLI の例。`--endpoint-url` は R2 の S3 エンドポイント):

```bash
aws s3 ls s3://etcd-backup/k8s2/ --endpoint-url "$R2_ENDPOINT" | tail
aws s3 cp s3://etcd-backup/k8s2/<TIMESTAMP>/etcd-snapshot.db.gz.age . --endpoint-url "$R2_ENDPOINT"
aws s3 cp s3://etcd-backup/k8s2/<TIMESTAMP>/pki.tar.gz.age .           --endpoint-url "$R2_ENDPOINT"

# 復号(秘密鍵は、Bitwarden から、一時ファイルに取り出す。使い終わったら消す)
age -d -i etcd-backup.key etcd-snapshot.db.gz.age | gunzip > snapshot.db
age -d -i etcd-backup.key pki.tar.gz.age | tar -xz        # pki/ と admin.conf
```

## 復旧の手順

### A. メンバーが 1 台だけ壊れた(quorum は保たれている)

スナップショットは要らない。壊れたメンバーを外して、再参加させる。

```bash
# 動いているノードの etcd で(例: k8s4 の etcd コンテナ)
kubectl -n kube-system exec etcd-k8s4 -- etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table
# 壊れたメンバーを削除し、kubeadm で参加し直す(hardware/modules/k8s-control-plane の手順)
```

### B. 全体の復旧(quorum を失った、またはデータが壊れた)

**この手順は、クラスターを、スナップショットの時点に戻す。それ以降の変更は失われる(RPO)。**

1. **スナップショットを取り出して、復号する**(上の手順)。`etcdutl snapshot status snapshot.db` で、整合性を確認する。
2. **全ての control-plane で、etcd と kube-apiserver を止める**(static pod のマニフェストを退避する)。

   ```bash
   sudo mkdir -p /root/manifests-stopped
   sudo mv /etc/kubernetes/manifests/{etcd,kube-apiserver}.yaml /root/manifests-stopped/
   ```
3. **各ノードに、スナップショットを置き、`etcdutl` で restore する**。kubeadm の etcd イメージには `etcdutl` が無いので、同じバージョンの etcd のリリース(`etcd-v3.5.16-linux-amd64.tar.gz`)から、`etcdutl` を取り出して使う。各ノードで、`--name` と `--initial-advertise-peer-urls` を、そのノードのものにする。

   **`--bump-revision 1000000000 --mark-compacted` は必須。** restore すると、リビジョンがスナップショットの時点まで巻き戻る。kube-apiserver や controller の watch は、巻き戻る前の(より新しい)リビジョンを覚えているので、このままだと、古い cache のまま更新を取り逃がす。リビジョンを大きく先へ進めて(`--mark-compacted` で、その地点を compaction 済みにする)、全ての watcher に、再同期(relist)を強制する。**3 台全てで、同じ値**を使う。

   ```bash
   sudo mv /var/lib/etcd /var/lib/etcd.broken-$(date +%s)
   sudo etcdutl snapshot restore snapshot.db \
     --bump-revision 1000000000 --mark-compacted \
     --name k8s2 \
     --initial-cluster k8s1=https://192.168.1.103:2380,k8s2=https://192.168.1.20:2380,k8s4=https://192.168.1.120:2380 \
     --initial-cluster-token etcd-restore-$(date +%Y%m%d) \
     --initial-advertise-peer-urls https://192.168.1.20:2380 \
     --data-dir /var/lib/etcd
   ```
4. **マニフェストを戻して、etcd → kube-apiserver の順に起動する**(3 台とも)。

   ```bash
   sudo mv /root/manifests-stopped/etcd.yaml /etc/kubernetes/manifests/
   # etcd が 3 台揃って healthy になってから
   sudo mv /root/manifests-stopped/kube-apiserver.yaml /etc/kubernetes/manifests/
   ```
5. **確認する**: `etcdctl endpoint status --cluster -w table`(3 台、同じ raft index)、`kubectl get nodes`、`kubectl get pods -A`。
6. **復旧後**: スナップショット以降に作られたリソース(ArgoCD が管理するものは、自動で戻る)と、Rook / Ceph の状態を確認する。ワーカーの kubelet を再起動すると、API の状態に追随する。

### C. control-plane を、ノードごと作り直す

`pki.tar.gz.age` を復号し、`/etc/kubernetes/pki` と `admin.conf` を、新しいノードに置く。そのうえで、B の手順の restore と、`kubeadm` の手順(`hardware/modules/k8s-control-plane`)を行う。

## restore テスト(定期的に行う)

**四半期ごとに 1 回、最新の本番のスナップショットで、隔離環境の restore を確認する。** バックアップがあっても、restore できなければ意味が無い。

```bash
# 手順の確認(自前のデータ。docker だけで動く)
bash hardware/modules/etcd-backup/test-restore.sh --selftest

# 本番のスナップショット(上の手順で取得・復号したもの)
bash hardware/modules/etcd-backup/test-restore.sh snapshot.db      # .gz も可
```

結果は、`docs/` に日付を付けて記録するか、issue にコメントする。本番のスナップショットは、全ての Secret を含むため、確認後に、必ず手元から消す。

## 監視

- メトリクス(`etcd_backup_*`、node_exporter の textfile): `etcd_backup_last_success_timestamp_seconds`、`etcd_backup_last_run_success`、`etcd_backup_snapshot_bytes`、`etcd_backup_duration_seconds`。
- アラート(「最後の成功から 3 時間以上」)は、node_exporter の textfile collector を有効にする別の変更と、一緒に入れる(`platform/monitoring`)。それまでは、`journalctl -t etcd-backup` と `systemctl is-failed etcd-backup.service` で確認する。

## 注意

- 2026-10-07 時点で、etcd の DB は 1.69 GB(実使用は 0.10 GB)で、既定のクォータ 2 GiB の約 85% に達している。断片化が原因で、`defrag` が必要。スナップショットのサイズも、これに引きずられる(圧縮するので、実際は小さい)。
- k8s2 以外(k8s1: 空き 8 GB、k8s4: 空き 2.6 GB)は、ディスクが小さいので、スナップショットを取る場所にしない。k8s2 が長く落ちる場合は、`etcd-backup` モジュールを、別のノードにも入れる(`ディスクの空き > DB のサイズ + 1 GB` を、スクリプトが確認する)。
