# Harbor の DB が `has invalid permissions` で起動しないときの復旧手順

issue #243。2026-10-08 に、Harbor の DB(`harbor-helm-database-0`)が CrashLoopBackOff(398 回)になり、Harbor 全体が止まり、25 個以上の Pod が `ImagePullBackOff` になった。**データは失われておらず、Pod を削除して init container を再実行させるだけで復旧した。**

## 症状
```
harbor-helm-database-0   0/1   CrashLoopBackOff
FATAL:  data directory "/var/lib/postgresql/data/pgdata/pg15" has invalid permissions
DETAIL:  Permissions should be u=rwx (0700) or u=rwx,g=rx (0750).
```
- `harbor.kigawa.net/v2/` が 503 を返す。
- Harbor のイメージを使う Pod が、`ImagePullBackOff` / `ErrImagePull` になる。

## 原因
- Harbor のチャート(`harbor` 1.15.1)の DB の StatefulSet は、Pod に `securityContext: {runAsUser: 999, fsGroup: 999}` を固定で持つ(values では変えられない。最新の 1.19.2 でも同じ)。
- `fsGroup` があると、kubelet は、ボリュームのマウントのたびに、グループに `rw` と setgid を付ける(ディレクトリは `2770`、ファイルは `0760` など)。PostgreSQL は、データのディレクトリにグループの書き込み権があると、起動を拒否する。
- チャートは、これを、init container `data-permissions-ensurer`(`chmod -R 700 .../pgdata || true`)で直す。**ただし、init container は、Pod の起動時の 1 回だけ**動く。Pod が動いている間に、kubelet が、`fsGroup` を、もう一度適用すると(kubelet の再起動後、ノードの障害時など)、パーミッションが `2770` に戻り、**コンテナだけが再起動し続けても、直らない**。

## 診断(読み取り専用)
1. **DB が使っている PVC と PV を確認する**(古い、使っていない PVC と取り違えない):
   ```bash
   kubectl -n harbor get pod harbor-helm-database-0 -o jsonpath='{.spec.volumes[?(@.name=="database-data")].persistentVolumeClaim.claimName}'
   kubectl -n harbor get pvc            # 該当の PVC の VOLUME(PV 名)を控える
   ```
2. **ボリュームが、実際にマウントされ、データがあるか確認する**。Pod が動いているノード(`kubectl -n harbor get pod -o wide`)で:
   ```bash
   pv=<PV 名>
   m=$(find /var/lib/kubelet/pods/*/volumes/kubernetes.io~csi/$pv/mount -maxdepth 0)
   stat -c '%a %u:%g %n' $m/pgdata/pg15        # 2770 なら、この症状(0700 / 0750 が正常)
   ls -ln $m/pgdata/pg15 | head
   cat $m/pgdata/pg15/PG_VERSION               # 15
   du -sh $m/pgdata
   ```
   所有者が uid 999 で、`PG_VERSION` と `base/` などが読めれば、**データは残っている**。

## 復旧
1. **控えを取る**(DB は止まっているので、安全)。ノード上で、`pgdata` を、root 専用のディレクトリにコピーする:
   ```bash
   d=/root/harbor-db-pgdata-backup-$(date +%Y%m%d); mkdir -m 700 $d && cp -a $m/pgdata $d/
   # 元と控えの、ファイル数と合計バイトが一致することを確認する
   ```
2. **Pod を削除する**(PVC は削除しない)。StatefulSet が再作成し、init container が `chmod -R 700` を、`fsGroup` の適用の後に実行する:
   ```bash
   kubectl -n harbor delete pod harbor-helm-database-0
   ```
3. **起動を確認する**: `kubectl -n harbor get pod harbor-helm-database-0`(`1/1 Running`)。続いて、Harbor の `core` / `jobservice` / `registry` が復旧し、`curl -s -o /dev/null -w '%{http_code}\n' https://harbor.kigawa.net/v2/` が **401**(認証を求める = 正常)を返す。`ImagePullBackOff` の Pod は、時間とともに解消する。
4. 動作が安定したら、控えを削除する。

## つまずきやすい点(2026-10-08 に実際に起きた)
- **新しい Pod が、I/O の重いノード(k8s-worker5)に載ると、起動しない**。worker5 のルートは HDD で、containerd が、サンドボックスの作成で時間切れ(`DeadlineExceeded`)を起こし、名前が予約されたまま(`failed to reserve sandbox name`)詰まる(#182)。
  - 症状: Pod が、数十分、`Pending` / `PodInitializing`。`kubectl describe pod` に `FailedCreatePodSandBox`。
  - 対処: worker5 の containerd を再起動する(`KillMode=process` を確認してから。コンテナは止まらない)。効かなければ、時間をおく(20〜40 分で、自然に通ることがある)。worker5 を避けたいときは、`cordon` を検討する(新しい Pod が来なくなるだけで、既存の Pod は止まらない)。
- **`stuck-pod-reaper`** は、「10 分以上 Pending」の Pod を強制削除する。`kigawa-system-rook-ceph` の Pod は、#267 で対象から外したが、**ほかの namespace の、起動に時間のかかる Pod は、削除されうる**(Deployment / ReplicaSet の Pod。StatefulSet は対象外なので、Harbor の DB は、対象外)。
- **古い、孤児の PVC を、DB のものと取り違えない**。`database-data-harbor-database-0`(`ceph-rbd`、旧 pool `k8s` を指す)は、使っていない古い PVC。いまの DB は、`database-data-harbor-helm-database-0`(`rook-ceph-rbd`)。

## 再発防止(未実施の案)
- Pod に `fsGroupChangePolicy: OnRootMismatch` を足せば、kubelet が、ルートの権限が合っているときに、再帰的な変更をしなくなる。ただし、チャートは、これを values で設定できない。ArgoCD の Application を、Helm の後処理(kustomize など)に変える必要があり、**Application の構造を大きく変える**ため、見送った。また、一度 `2770` になったボリュームでは、最初の 1 回は、再帰的な変更が走るため、**init container の `chmod` は、引き続き必要**で、再発を確実に防ぐ手段かは、検証が要る。
- 監視: `kube_pod_container_status_restarts_total` と `CrashLoopBackOff` のアラートで、DB の再起動の繰り返しに、早く気づく(今回は、Harbor の DB が、数日間、再起動を繰り返して、398 回に達した。issue の作成時の 10/5 には、57 回だった)。

## 参考: この障害で分かった、#243 の本来の前提との食い違い
- issue は、「旧 pool `k8s` の消滅で、Harbor の DB が壊滅し、再構築が前提」としていたが、実際の DB は、別の正常な PV を使っていた。`pool=k8s` を指す PV は、10 件あるが、使っている Pod があるのは `icha/db-data` だけで(その PVC は、別の正常な PV に束縛)、残りは、使っていない孤児の PVC。元の image は、どの pool にも、ゴミ箱にも、存在しない。孤児の PVC・PV の整理は、別途。
