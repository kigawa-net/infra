# 本番クラスタへの GPU ノード追加 設計書(ドラフト)

2026-11-08 時点。ブランチ `feat/gpu-cluster`。対象は worker5(RTX 3060 12GB、本番サイト)。

## 1. 目的

本番クラスタ(kubeadm HA)で LLM 推論と AI ワークロード(推論サーバー、AI エージェント実行)を動かす。現状、実用的な GPU は無い(worker3 の GTX 650 / Kepler のみ。VRAM 1〜2GB 級で LLM には使えない)。

自宅 main の開発環境(OpenCode + code-server、#470)の LLM の向き先としても使えるようにする。

## 2. 現状(リポジトリから確認できたこと)

- `hardware/k8s-worker3/main.tf` に GPU 設定が**インライン**で入っている(`nvidia-driver-470` + NVIDIA Container Toolkit + `nvidia-ctk runtime configure --runtime=containerd`)。Kepler は 470 が最終対応のため固定している。
- 他のワーカー(`k8s-worker1/4/5`)は同じ「`null_resource` + SSH + kubeadm join」のテンプレート。GPU 設定は無い。
- クラスタ側(device plugin、RuntimeClass、taint)の定義は、このリポジトリには無い(`application/` `platform/` は空)。ArgoCD の manifest リポジトリ側に置く想定(要確認)。
- issue #302「worker2 に NVIDIA GPU 2 枚(RTX 3060 / GTX 750 Ti)」が open。`hardware/` に worker2 は無く、内容は未検証(コメントなし、Ubuntu 24.04 / kernel 6.8 の記述)。**#302 の機器が実在・稼働中なら、新規機ではなくこれを使うのが最短**。要確認。

## 3. 設計

### 3.1 ノード側: `hardware/modules/nvidia-gpu-node`(新規)

worker3 のインライン GPU ブロックを、再利用できるモジュール(スクリプト断片を出力する)に切り出す。**worker5 がそれを使う**。worker3 の置き換えは今回のスコープ外(動いているので触らない)。

| 入力 | 意味 |
|---|---|
| `driver_package` | worker5 は Ampere のため `nvidia-driver-<570 以降>-open` または `-server`(Ubuntu 24.04 の標準リポジトリ。導入前に `apt-cache policy` で確認)。Kepler の worker3 は 470 固定で別 |
| `container_toolkit_version` | バージョン固定する |

- ドライバは Ubuntu 標準リポジトリのパッケージを使い、PPA は避ける(再現性)。`apt-mark hold` で固定する。
- Container Toolkit を入れ、`nvidia-ctk runtime configure --runtime=containerd`(`--set-as-default` はしない。RuntimeClass `nvidia` で選ぶ)。
- 初回は再起動が必要。join → ドライバ → 再起動 → `nvidia-smi` 確認の順にし、失敗時は既存どおり `trap cleanup` でロールバックする。
- 対象は**既存の `hardware/k8s-worker5`**(`192.168.1.150` / `10.0.0.40`、GPU は搭載済み)。新ノードは作らない。
- worker5 は join 済みで稼働中。`null_resource` は `triggers = { host }` + `ignore_changes` で再実行されないため、GPU 設定は**別の `null_resource`**(`nvidia_gpu`)として追加し、既存のセットアップ(kubelet_image_gc と同じ方式)に倣う。
- 手順: `kubectl drain` → ドライバ・Toolkit 導入 → 再起動 → `nvidia-smi` 確認 → `uncordon`。失敗時はドライバのパッケージを purge して containerd 設定を戻す。
- 事前確認(2026-11-08 実測): OS は Ubuntu 24.04.5 / kernel 6.8.0-147、`/` は SSD 457G 中 43G 使用(空き 392G)。ドライバは**未導入**(`nvidia-smi` なし)。内蔵 GPU(Intel UHD 630)もあるため、ディスプレイ出力に影響しないか確認。#65(containerd リーク)の状況は未確認。

### 3.2 クラスタ側(ArgoCD、別リポジトリ)

1. **NVIDIA device plugin**(DaemonSet)。ホストにドライバがある前提なので GPU Operator は使わない(コンポーネントが多く、1 台構成には過剰)。
2. `RuntimeClass: nvidia`。GPU を使う Pod は `runtimeClassName: nvidia` + `resources.limits."nvidia.com/gpu": 1`。
3. ノードに `nvidia.com/gpu=present:NoSchedule` の taint とラベル(GPU 型番・VRAM)。GPU を使わない Pod が載らないようにする。
4. 推論サーバー(llama.cpp server か vLLM。要確定)を `gpu` namespace に Deployment + ClusterIP Service で置く。モデルは PVC(ローカル NVMe 推奨。Ceph は worker1 が I/O 飽和気味 #240 なので避ける)。
5. 複数ワークロードで 1 枚を共有する場合のみ time-slicing を検討する(VRAM は分割されない点に注意)。

### 3.3 ネットワークと開発環境からの利用

- **置き場所が本番サイト**: 他の worker と同じ LAN(10.0.0.x)に置き、通常の kubeadm join。追加のネットワーク作業は無い。自宅 main の開発 Pod からは、推論 Service を IONOS ゲートウェイ/オーバーレイ経由で呼ぶ(#470 と同じ経路と認証に載せる)。LLM API は Keycloak 配下か、固定トークン + 送信元制限にする。
- **置き場所が自宅側**: 本番クラスタのノードとして WAN 越しに join するのは勧めない(kubelet↔apiserver、flannel の Pod ネットワーク、etcd 遅延と、現在進行中のオーバーレイ BGP/GRE 作業(#418 など)に依存する)。代わりに、自宅側 GPU は**ノードにせず**、自宅 main のクラスタか単体ホストで推論サーバーを動かし、エンドポイントだけを本番側へ公開する。

### 3.4 マシン選定の目安(LLM 用途)

| VRAM | 動かせる目安(4bit 量子化) |
|---|---|
| 8GB | 7〜8B モデル |
| 12GB | 8〜14B |
| 24GB | 〜32B |

エージェント実行(長いコンテキスト)は KV キャッシュで VRAM を食うため、余裕を見て 12GB 以上を推奨。

## 4. 実装の流れ(issue → PR 単位)

1. `nvidia-gpu-node` モジュールと README(worker3 のブロックを参考に切り出し)。
2. `hardware/k8s-worker5` に GPU 用 `null_resource` を追加(`plan` で確認 → drain → apply)。
3. ArgoCD 側: device plugin・RuntimeClass・taint の manifest。
4. 動作確認 Pod(`nvidia-smi`)と、推論サーバーの試験デプロイ。
5. 開発環境(#470 の公開経路)から LLM を呼ぶ設定。

## 5. 未決事項

1. ~~どのマシンか~~ → **worker5**(決定。GPU 搭載済み)。**RTX 3060(GA106, `10de:2504`、LHR。この ID は 12GB 版)**。2026-11-08 に SSH で確認。#302 の「worker2」の記述(RTX 3060・Ubuntu 24.04・kernel 6.8.0-147)は worker5 の実機と一致するため、#302 は実質 worker5 の件とみなせる。
2. ~~置き場所~~ → **本番サイト**(決定)。3.3 は本番サイト側の方針を採る。
3. 推論サーバーは llama.cpp か vLLM か(自宅は llama.cpp 運用中。GPU が NVIDIA なら vLLM も選べる)。
4. device plugin 等の manifest をどのリポジトリに置くか。
