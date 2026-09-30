# Kubernetes マイナーバージョンアップグレード手順

kigawa-net/infra#158(1.29→1.30アップグレード)で実際に使用・検証した手順。
次回以降のマイナーバージョンアップグレード(例: 1.30→1.31)でも同じ流れを
踏襲できるよう、実行順序・コマンド・遭遇した問題と回避策を記録する。

## 前提

- kubeadmのversion skew policyに従い、**1 minorずつ**段階アップグレードする
  (1.29→1.31のような2ホップ同時アップグレードは行わない)
- 実行前に対象control-planeでetcdスナップショットを取得しておく
  (`/var/lib/etcd/pre-upgrade-backup.db` のようなhostPath上に保存し、
  ホスト再起動後も残るようにする)
- apt repoファイル(`/etc/apt/sources.list.d/kubernetes.list`)と
  `kubeadm`/`kubelet`/`kubectl`の`apt-mark hold`状態を事前に確認する

## 実行順序

**control-plane → worker** の順。control-planeは1台目のみ
`kubeadm upgrade apply`、2台目以降は`kubeadm upgrade node`。

workerは、既往症・役割を考慮して優先度を決める。今回(1.29→1.30)は
`worker3 → worker5 → worker1 → worker4`の順で実施した
(worker4は慢性的な過負荷のため最後・かつ要注意、worker1はSSH不安定の既往)。

## 基本手順(1ノードあたり)

```bash
ssh <node>

# 1. apt repoを対象バージョンへ切り替え
sudo sed -i 's|/core:/stable:/vX.YY/|/core:/stable:/vX.ZZ/|' /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update

# 2. kubeadmのみ先に上げる
sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm='X.ZZ.W-1.1'
sudo apt-mark hold kubeadm
kubeadm version

# 3. プラン確認(必ず目視確認してから次へ)
sudo kubeadm upgrade plan

# 4. 適用: 1台目(cluster全体で最初のcontrol-plane)のみ apply、それ以外は node
sudo kubeadm upgrade apply vX.ZZ.W   # 1台目のcontrol-planeのみ
# sudo kubeadm upgrade node          # 2台目以降のcontrol-plane、および全worker

# 5. kubelet / kubectl を上げてから再起動
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet='X.ZZ.W-1.1' kubectl='X.ZZ.W-1.1'
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet

exit
```

drain/uncordonはbest practiceだが、hostPathで特定ノードに固定される
コンポーネント(下記「発見した既知の落とし穴」参照)がある場合はスキップし、
kubelet再起動のみで済ませる判断もあり得る。

**各ノード完了後の確認**: `kubectl get nodes` で対象ノードが目的バージョン
かつ `Ready` になっていることを確認してから次のノードへ進む。

## 発見した既知の落とし穴(1.29→1.30実施時)

### kubeadmの5分タイムアウトによる自動ロールバック

`kubeadm upgrade apply`/`upgrade node`は新しいstatic pod manifest
(kube-apiserver.yaml等)を書き込んだ後、pod hashの変化を最大5分待つ。
ディスクI/O競合等でこの5分を超えると**自動的に旧manifestへロールバック**
される。この安全機構を止めるには、"Moved new manifest to..."ログが出た
直後にkubeadmプロセス自体をkillし、kubelet自身の(無制限の)タイムライン
で処理を完了させるしかない。

### kubeadmのetcdバックアップ蓄積によるディスク逼迫

`kubeadm upgrade apply`/`upgrade node`は実行の度に無条件で
`/etc/kubernetes/tmp/kubeadm-backup-etcd-<timestamp>/`(約2GB)への
etcdバックアップを試みる。自動削除されないため、リトライを繰り返すと
15GB程度のrootディスクではすぐに埋まる。定期的な手動クリーンアップが
必要。

### kubeletのephemeral-storage eviction manager loop

`df`上は空き容量があるように見えても、kubelet内部の
ephemeral-storage会計により継続的なeviction試行(約10秒間隔)が発生し、
コンテナ再起動を妨げることがある。`/var/lib/kubelet/config.yaml`に
明示的な`evictionHard`しきい値を追加してkubeletを再起動すると止まる。
**作業完了後は必ずデフォルトへ戻すこと**(将来の本当のディスク逼迫を
隠してしまうため)。

### containerdのstale reservationバグ

過負荷ノードでcontainerdのコンテナ/サンドボックス名前予約が
スタックすることがある(`"failed to reserve container name ... is
reserved for <hash>"`)。`kubectl delete pod <name> --force
--grace-period=0`で完全に新しいPod UID/名前を強制することで解消する。
過負荷が収まっていない場合は複数回発生することがある。

### Rook-Cephのmon hostPathピン留め

hostPathでmonのデータディレクトリを持つRook-Cephクラスタでは、
Operatorが該当monのDeploymentに`nodeSelector`
(`kubernetes.io/hostname: <node>`)を設定し、常に同じノードへ再配置
されるようにしている。このノードをcordon/drainすると、monが
Pendingになりquorumが劣化し、OSDのPodDisruptionBudgetがcluster全体の
evictionをブロックしてしまう。対象ノードでは**cordon/drainを行わず、
kubelet再起動のみ**で済ませるのが安全(全Pod瞬間的に再起動されるが、
再スケジュール先を探さずに元のノードへ戻る)。
`kubectl get deploy -n <rook-ns> -l app=rook-ceph-mon -o
jsonpath='{...nodeSelector...}'`で事前に該当有無を確認すること。

## 完了後の作業

- `kubectl get nodes -o wide` で全ノードが目的バージョン & `Ready`
- etcd cluster health確認(`etcdctl endpoint health --cluster -w table`)
- kube-vip / Flannel / BGP(bird)/ WireGuardが正常か確認
  (VIPを保持しているcontrol-planeを再起動する際はfailover先を確認)
- `hardware/*/variables.tf`の`k8s_version`デフォルト値を更新するPR作成
- 本docsの内容を更新(新たな落とし穴が見つかった場合は追記)

## ロールバック手順

control-plane 1台が起動不能になった場合、残りのetcdメンバーでクラスタは
継続動作するはずなので、まず問題のノードを切り離して調査する。完全復旧
不能な場合は、正常な1台から取得したetcdスナップショットを使い、
[kubeadmの災害復旧手順](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/#restoring-an-etcd-cluster)
に従ってetcdクラスタを再構築する。
