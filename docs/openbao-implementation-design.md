# OpenBao Secret 管理基盤 実装設計

全体設計 v1.0(Secret管理基盤)を、このリポジトリ(Terraform + SSH provisioner + `bws`)で実装できる粒度に落とした設計。ステータス: **ドラフト**(未着手、issue 未作成)。

## 0. 前提(全体設計 §12 の未確定事項の仮置き)

全体設計が「推奨」とした選択肢を仮置きする。違う場合はこの節だけ差し替える。

| 事項 | 仮置き | 実装への影響 |
|---|---|---|
| 第3拠点 | 独立した第3拠点(**ホスト未定**) | `bao-03` のホスト・WireGuard 経路が決まるまで Phase 1 は 2 ノード+未参加の状態で進めない(下記 §3) |
| Unseal | Shamir 5/3 手動 | 再起動時に人手が要る。§6 の運用で担保 |
| バックアップ先 | 外部 S3 互換 + Object Lock | **Cloudflare R2 は Object Lock 非対応**。既存の `etcd-backup` と同じ R2 は使えない(§7) |

### 0.1 bao-01 の配置(決定: Inuyama の Kubernetes 上の StatefulSet)

全体設計は「Kubernetes・Ceph に依存させない」としていたが、**bao-01 は Inuyama の K8s 上の Pod(StatefulSet)として動かす**ことに決めた。bao-02(IONOS の別 VPS)・bao-03(第3拠点)は、従来どおり systemd(`modules/openbao-node`)。

この決定で変わること:

- **bao-01 は `modules/openbao-node` を使わない**。manifest は `kigawa-net-k8s`(ArgoCD GitOps)側で管理する。`hardware/bao-01`(PR #328)は、bao-02 / bao-03 用に `hardware/bao-02` へ改名・流用する。
- **bao-01 用の WireGuard ピアは追加しない**。bao-02 / bao-03 から bao-01 への経路は、K8s の LoadBalancer(kube-vip の VIP、10.0.0.x)を既存の WireGuard / BGP 経由で到達させる。`cluster_addr` もこの VIP(または専用 VIP)を使う。VIP の払い出しと、IONOS 側のルート広告を確認する。
- **ストレージ**: Ceph の PV には載せない。ローカル SSD の PV(local PV / hostPath 固定)を使い、Pod を特定ノードに固定する。
- **残るリスク(受け入れる)**: K8s の停止・再構築で、bao-01 が同時に落ちる。3 voter のうち 1 つなので、bao-02 / bao-03 が生きていれば継続する。ただし **K8s と別の 1 拠点が同時に落ちるとクォーラムを失う**。さらに、K8s が bao-01 に Secret を取りに行く構成(ESO)になると、K8s の再起動時に OpenBao の復旧が K8s の復旧を待つ循環が起きうるので、**K8s の起動に必要な資格情報は OpenBao に依存させない**(§1)。
- **バックアップ実行ホストは、引き続き K8s の外**(§7)。Raft の復旧演習では「K8s 全損 + bao-01 消失」の場合を明示的に含める。

## 1. このリポジトリに合わせた設計判断

- **ノード構築は既存パターンを踏襲する**: `hardware/<node>/` を独立 root module とし、`null_resource` + SSH provisioner で setup script を流す。共通部分は `hardware/modules/openbao-node/` に切り出す(`k8s-control-plane` と同じ位置づけ)。
- **OpenBao の中身の設定(auth / policy / engine)は別 root module `platform/openbao-config/`**(Terraform `vault` provider は OpenBao 互換)。ノード構築(`hardware/`)と論理設定(`platform/`)は、state・権限・変更頻度が違うので分ける。`platform/` は現状空なので、ちょうど使い道になる。
- 全体設計 §10 の `infra/openbao/` ディレクトリ案は採らず、上記 `hardware/` + `platform/` に割り付ける。
- シークレットの取得は **`lib/bws-retry.sh` の `bws_get_value` のみ**(CLAUDE.md の規約)。OpenBao 自身の Unseal 鍵・root token は Bitwarden に置かない(下記 §6)。
- **循環依存の禁止**: OpenBao の構築・復旧に必要な資格情報(SSH 鍵、sudo パスワード、R2/S3 キー)は引き続き `bws` から取る。OpenBao 移行後も、これらを OpenBao に移さない。

```
hardware/
  modules/openbao-node/      # install / config / systemd / TLS 配置 / node_exporter 連携
  modules/openbao-backup/    # backup runner(systemd timer、etcd-backup を雛形に)
  bao-01/ bao-02/ bao-03/    # ノードごとの root module(state key: hardware/bao-0N/terraform.tfstate)
platform/
  openbao-config/            # policy / auth / secrets engine / audit device
docs/
  openbao-implementation-design.md   # 本書
  openbao-restore.md                 # Phase 3 で作成(復旧手順 + 演習記録)
```

## 2. ノード実装(`modules/openbao-node`)

| 項目 | 内容 |
|---|---|
| OS / 導入 | Ubuntu(既存ノードと同じ)。OpenBao は公式 `.deb`(or バイナリ)を**バージョン固定+SHA256 検証**で導入。`apt` 追従にしない |
| 実行 | systemd unit `openbao.service`、専用ユーザー `openbao`、`NoNewPrivileges` / `ProtectSystem=strict` / `MemoryDenyWriteExecute` / `LimitCORE=0`、swap 無効(または `mlock` 有効) |
| データ | ローカル SSD の `/var/lib/openbao`(Ceph・NFS 禁止)。単独ディスクの `ext4` |
| Storage | `storage "raft"`(`node_id`、`retry_join` に他 2 ノードの TLS URL) |
| Listener | `:8200`(API)・`:8201`(cluster)ともに `tls_min_version = "tls13"`。bind は **WireGuard IP とループバックのみ**(公開 IF に bind しない) |
| `api_addr` | `https://<fqdn>:8200`(`bao-0N.kigawa.net`。TLS の証明書の名前と合わせる) |
| `cluster_addr` | WireGuard 上の固定 IP |
| テレメトリ | `telemetry { unauthenticated_metrics_access = false }`。Prometheus は専用 token(`sys/metrics` read のみ)で scrape |
| ホストFW | 8200: 認証済みクライアントの経路のみ / 8201: bao ノード間のみ / 22: 管理網のみ(全体設計 §3 の表どおり) |
| ログ | journald → Loki。既存 `modules/journald-limit` を適用して肥大を防ぐ |
| ロールバック | 既存 setup script と同じく `trap cleanup EXIT`。**ただし `/var/lib/openbao` は cleanup で消さない**(初期化後の誤削除防止。初回構築失敗時のみ明示フラグで消す) |

### TLS(決定: Let's Encrypt + DNS-01、ノードごとに証明書を発行)

OpenBao の外側にある CA(公開 CA の Let's Encrypt)で発行する。OpenBao 自身の PKI には依存しない(循環の防止)。

- **名前**: `bao-0N.kigawa.net`(ノードごとに別の証明書)。公開の CT ログに名前が載る。IP は載らない。名前の解決は、`/etc/hosts` か内部 DNS(knot)で WireGuard 内の IP に向ける。公開 DNS に A レコードは置かない。
- **発行・更新はノード自身が行う**(`certbot` + `python3-certbot-dns-cloudflare`、systemd timer)。証明書の秘密鍵はノードの外に出ない。**Terraform の state にも bws にも、TLS の秘密鍵は入らない**(これで、`openbao-node` が `tls_key_pem` を state に持つ問題がなくなる)。更新後は、deploy hook で OpenBao に `SIGHUP`(再読込)を送る。
- **DNS-01 のトークン(決定: 専用ゾーンは作らず、`kigawa.net` ゾーンのトークンを使う)**: Cloudflare のトークンは、`kigawa.net` ゾーンの「DNS 編集」だけの権限にする(アカウント全体や、他のゾーンには届かない)。**トークンは、Cloudflare の「クライアント IP アドレスのフィルタ」で、bao ノードの公開 IP だけに制限する**(bao-02 は 207.231.111.196)。トークンは bws に置く(OpenBao には置かない。循環の防止)。
  - **受け入れるリスク**: Cloudflare のトークンは、レコード名では権限を絞れない。bao ノードの root が奪われると、`kigawa.net` の DNS レコードを書き換えられる。IP 制限と、ノードの堅牢化(SSH は鍵のみ、ufw)で軽減する。専用ゾーンへの CNAME 委任なら、この影響範囲を狭められる。**将来、別ドメインを用意できたときに、委任へ移行できる**(`certbot` の設定は、トークンと `--dns-cloudflare-credentials` の向き先を変えるだけ)。
  - **bao-01(K8s 上)**: certbot ではなく cert-manager(Cloudflare の DNS-01)で発行する。トークンは、K8s の Secret に置き、bao-01 の Namespace 限定にする。この Secret は OpenBao に依存させない。
- **`retry_join` は FQDN で指す**(`https://bao-0N.kigawa.net:8200`)。公開 CA の証明書なので、`leader_ca_cert_file` は不要(OS の信頼ストアで検証する)。
- **Raft のノード間通信(8201)** は、OpenBao が自己管理する証明書で行う。外部 CA の対象ではない。

**API の公開(Cloudflare Access / OAuth proxy)**: GitHub Actions(JWT Auth)や人間の CLI から、WireGuard の外で API に届かせるため、API(8200)は `kigawa.net` の名前で、Cloudflare Access または oauth2-proxy を前に置く方針。次の線は守る。
- bao ノードの 8200/8201 は、引き続き **WireGuard 上だけ**で待ち受ける(ufw でも wg0 だけを許可)。公開側の入口は、別の経路(Cloudflare Tunnel など)にする。ノードの公開 IP に、8200 を開けない。
- Access / proxy は、OpenBao の認証・認可(OIDC / JWT / Policy)の**代わりではなく、その手前の追加の層**として扱う。
- 非ブラウザのクライアント(GitHub Actions、ESO)には、Access のサービストークンなどが必要になる。具体的な構成は、Phase 2(認証)の設計で決める。
- 内部 TLS を OpenBao PKI Engine + cert-manager で出すのは **Phase 6**。bao ノード自身の証明書は対象外。

### ネットワーク(WireGuard)

- 既存の `modules/wireguard` / `ionos` ハブ構成(`docs/wireguard-network-map-design.md`)に **bao 用のピアとアドレスを追加**する。bao-01(Inuyama)・bao-02(IONOS)は既存網に載せられる。
- **bao-03 は host-hye1(`143.203.220.195`、Debian 13、2 vCPU / 1.9GB)に決定**(2026-10-28、#359 で WireGuard `172.31.254.31/32` を適用済み)。bao-02(ServerCheap、`172.31.254.30`)・bao-03 とも、ハブ(ionos)の WireGuard に `/32` で参加している。bao-01(K8s 上)は、K8s のノード経由の `10.0.0.x` の VIP で届く。
- **実測の RTT(bao-03 から、2026-10-28)**: ハブ 42.7ms、bao-02(ハブ経由)53.6ms、Inuyama 約 197ms。bao-02 → Inuyama は約 167ms。
- 重要: 既存の WireGuard 設計メモの注意(同一 `AllowedIPs` を複数ピアに割り当てない、issue #121)に従う。bao 用 /32 だけを個別ピアに割り当てる。
- Phase 1 の合格条件に **拠点間 RTT / loss の実測**(全体設計 §3 の要求)を入れる。目安: Raft の `heartbeat_timeout` 既定値(1s)に対し、RTT p99 が十分小さいこと(下記 §9)。

### Raft の経路(ハブの SPOF への対策)

現状の WireGuard は、ハブ(ionos-01)を中心にしたスター型で、**bao ノード同士の通信が、すべてハブを経由する**。ハブが落ちると、3 ノードが互いに見えなくなり、Raft がクォーラムを失う。対策を、段階的に入れる。

1. **FQDN 経由で経路を切り替えられるようにしてある**: `retry_join` は `bao-0N.kigawa.net` を指し、解決は各ノードの `/etc/hosts` の管理ブロック(`modules/openbao-node`)が行う。**経路を変えるときは、`peers` の `address` を変えるだけ**で、OpenBao の設定(`retry_join`)は変えない。
2. **現在(Phase 1)**: `address` は WireGuard の IP(`172.31.254.30` / `.31`)。ハブ経由。
3. **目標**: bao-02 ↔ bao-03 は、EasyTier のオーバーレイ(`10.250.0.0/24`、`docs/network-vpn-architecture-design.md` §4.1)の P2P 直結に向ける。2 台とも公開 IP を持つので、直接の経路になる見込み。ハブ(ionos-01)が落ちても、bao-02 ↔ bao-03 の 2 ノードで、クォーラム(3 ノード中 2)を保てる。bao-01 は、Inuyama のゲートウェイ(オーバーレイ `10.250.0.11`)経由で参加する。
   - オーバーレイ上のアドレス: bao-02=`10.250.0.1`(ServerCheap)、bao-03=`10.250.0.31`(予約、`easytier_enabled` は未適用)。
   - **ufw の追加が要る**: 8200/8201 は、今は `wg0` 上だけ許可している。EasyTier の `tun0` でも許可する(`modules/host-hardening` の `tcp_ports_on_wireguard` を、インターフェースの一覧に拡張する)。
   - EasyTier が relay に回ると、遅延が増える。**採用バージョンでの、P2P 直結と relay の切替の実測**(設計書 §4.1 の要求)を、経路の切替の前提にする。
4. **切替の手順**: オーバーレイの疎通と RTT を実測 → bao-02 / bao-03 の `peers` の `address` を、オーバーレイの IP にする → ハブを止めた状態(WireGuard のハブへの接続を遮断)でも `bao status` が取れることを確認する。**OpenBao の導入前に、この切替の試験を終える**(導入後だと、Raft の `cluster_addr` の変更で、再起動が要る)。

### メモリ(bao-03 は 1.9GB)

bao-03 の RAM は、設計の目安(4GB)の半分(bao-02 は 3.9GB)。**`mlock` を有効にしたまま、小規模な Secret 管理で、数百 MB に収まる見込み**だが、余裕は少ない。
- 導入前に、メモリの使用量(RSS)の上限を `MemoryMax`(systemd)で決め、スナップショット取得時の増加を実測する。
- 実測で足りなければ、VPS のプランを上げる。足りる場合も、メモリ使用量の監視(`node_memory_MemAvailable_bytes`)を、Phase 2 の監視に入れる。

### クライアント側のエンドポイント冗長

`bao.internal.kigawa.net` の単一 LB は作らない。採用:

1. DNS に 3 ノードの A レコード(ヘルスチェックなしのラウンドロビン)+ クライアントは **standby へ来たら自動で leader に転送**される(OpenBao は request forwarding を標準でサポート)ことに依存する。
2. ESO など複数エンドポイントを持てないクライアント向けには、各クラスタ内に HAProxy(`/v1/sys/health?standbyok=true` でヘルスチェック)を置く。ここも冗長化(各 Pod 2 以上)。

DNS は既存の `knot` / `zones` を使う。ヘルスチェックなしの DNS ラウンドロビンは、停止ノードを返す間は 1 回のリトライで済む前提で許容する。

## 3. フェーズごとの実装タスク

issue は **フェーズごとの親 issue + 1 PR 1 テーマの子 issue** に分ける(リポジトリの運用: issue → ブランチ → PR、`Closes #N`)。

### Phase 1 — 独立基盤

1. `modules/openbao-node` を作成し、`bao-01`(Inuyama)のみで単独ノード初期化まで検証。
2. 外部 CA と TLS 配布手順(§2)を確定し、`docs/` に記述。
3. WireGuard に bao ピアを追加(ionos / k8s4 側。**他ピアの AllowedIPs が衝突しないことを plan で確認**)。
4. `bao-02`(IONOS)を追加し `retry_join` で参加。
5. **第3拠点を確定** → `bao-03` 参加で 3 voter。確定前は 1〜2 を本番利用しない。
6. `bao operator init`(5/3)を実施(§6 の手順)。root token は初期設定後に失効。
7. 拠点間 RTT/loss 計測の結果を記録。

合格条件: leader 切替(`bao operator step-down`)と 1 ノード停止で `bao status` が継続して取れる。`bao operator raft list-peers` が 3 voter。

### Phase 2 — 認証と監査

1. `platform/openbao-config` を作成(backend は `hardware/` と同様 R2、key `platform/openbao-config/terraform.tfstate`)。
2. **Audit Device を最初に有効化**(file → Loki への転送)。**audit device が 1 つも書けないと OpenBao は全リクエストを拒否する**ため、2 つ以上(file + syslog 等)を設定し、片方の障害で全停止しないようにする。ディスク逼迫時の挙動を試験する。
3. 管理者 OIDC(MFA)、ポリシー(`admin` / `backup` / `eso-<env>` / `ci-<repo>-<env>`)。
4. Kubernetes Auth(クラスタごとにマウントを分ける: `auth/k8s-prod`, `auth/k8s-stg`, `auth/k8s-dev`)。マウント名ごとに別 Role → dev から prod の Policy に到達できない。
5. GitHub Actions JWT Auth: `bound_claims` に **`repository` と `environment`(必要なら `ref`)を必ず固定**。`bound_audiences` も固定し、`sub` の glob は使わない。
6. Terraform に使う管理者権限は、**手元の人間(OIDC)のみ**。CI(`terraform.yml`)には OpenBao の管理権限を与えない(全体設計 §5)。
7. 監視(§8)。

### Phase 3 — バックアップと復旧(§7)

### Phase 4 — Kubernetes 統合

`kigawa-net-k8s` 側(ArgoCD GitOps、1 リソース 1 YAML、`{appname}-{kind短縮形}`)で ESO を導入する。**このリポジトリの責務は OpenBao 側の Role / Policy まで**。ClusterSecretStore は Namespace 単位の Policy に紐づけ、`ClusterSecretStore` を全 Namespace から使わせない。

### Phase 5/6 — 移行・動的 Secret

別設計(kivra Credential Broker、MariaDB Database Engine、PKI)。**前提として Phase 3 の復旧演習が完了していること**を着手条件にする。

## 4. Policy / Role の実装規約

- Policy は `platform/openbao-config/policies/*.hcl` に 1 ファイル 1 Policy。ファイル名 = Policy 名。
- KV v2 は `kv/` にマウント。パス規約: `kv/data/applications/<app>/<env>/*`。Policy は `data/` と `metadata/` を両方書く(全体設計 §5 の例のとおり)。
- 書込は `create`/`update` を明示した専用 Policy のみ。`read` Policy に `list` を付けるのは `metadata/` のみ。
- Policy の変更は PR レビュー必須。`plan` に Policy diff を出し、`sudo` や `sys/*`・`auth/*` を含む変更は、レビューで明示確認する。
- `default` Policy は Role に付与しない(`token_no_default_policy = true`)。
- token は短命(`token_ttl` 15 分〜1 時間、`token_max_ttl` 上限あり)。ESO 用 Role も同様で、`period` token は使わない。

## 5. 管理者アクセス

- 通常: OIDC + MFA。**OIDC は複数のプロバイダを別マウントで並べる**(OpenBao は auth method を任意のパスに複数マウントできる)。

| マウント | プロバイダ | 位置づけ |
|---|---|---|
| `auth/oidc-google` | Google | 主 |
| `auth/oidc-ms` | Microsoft(Entra ID) | 副 |
| `auth/oidc-keycloak` | Keycloak(K8s 上) | 日常利用のみ。**復旧経路には含めない** |

  - 権限は Role と外部グループ(identity group alias)で揃え、どの IdP から入っても同じ Policy になるようにする。IdP ごとに権限差が出ないことを `platform/openbao-config` のテストで確認する。
  - 全マウントで MFA 必須(IdP 側)、`bound_claims`(メールドメイン / グループ)・`allowed_redirect_uris` を固定する。
  - client secret は OpenBao に入れず `bws` で管理する(循環依存の禁止)。
  - **Keycloak は Kubernetes 上にあるため、復旧経路には含めない**(確定)。K8s 停止時に OpenBao 復旧のための認証が使えなくなるため。OpenBao 復旧時に使うのは Google / Microsoft の 2 つと break-glass。Keycloak の client secret・DB 資格情報も、OpenBao に依存させない(循環の防止)。
- **OIDC 非依存の緊急経路(break-glass)**: `userpass` を無効のまま用意し、有効化は Unseal 鍵保持者 3 名での `generate-root` 手順のみ。使用したら root token を即失効、Unseal 鍵・OIDC の再点検を行う。手順は `docs/openbao-restore.md` に含める。
- 注意: OIDC プロバイダ(どこに置くか)が **OpenBao の Secret を使う構成になると循環する**。OIDC の client secret や IdP 自身の資格情報は OpenBao に入れない。

## 6. 初期化と Unseal 鍵(Shamir 5/3)

`bao operator init -key-shares=5 -key-threshold=3` の出力を、**このリポジトリ・Terraform・`bws`・CI ログのいずれにも残さない**。

1. 実行は、人間が端末で直接行う(`terraform` の provisioner では初期化しない。出力が state / ログに入るため)。
2. 5 つの鍵を **PGP/age で個別の保管者の公開鍵に暗号化**して出力させる(`-pgp-keys`。age を使う場合は init 出力を直接 age に通す手順を `docs/openbao-restore.md` に固定)。
3. 保管者 5 名・保管先(オフライン媒体)を台帳化。3 名が揃わないと復旧できないので、**保管者の不在・退任時の再配布(`rekey`)手順**を決める。
4. 初期設定が終わったら root token を失効。

**要検討**: 再起動のたびに 3 名の手動 Unseal が必要。IONOS・第3拠点の VPS 再起動は予告なく起きうる。1 ノードの Sealed は許容(2 ノードで継続)だが、**2 ノード同時 Sealed でクォーラム喪失**になる。短期は Sealed 監視を最優先アラートにし、中期は独立 KMS による Auto Unseal(全体設計の「将来検討」)への移行判断を Phase 3 完了時に行う。

## 7. バックアップ(`modules/openbao-backup`)

既存の `modules/etcd-backup`(`etcd-backup.sh` + systemd timer + age 公開鍵暗号化 + node_exporter textfile)を雛形にして、差分だけ実装する。

| 項目 | etcd-backup | openbao-backup |
|---|---|---|
| 取得 | `etcdctl snapshot save` | `bao operator raft snapshot save` |
| 認証 | ノードの etcd | **専用 AppRole / JWT**。Policy は `sys/storage/raft/snapshot` の `read` のみ。token TTL 短く、Secret ID は 1 回限りではなくホストに置く(ここは OpenBao 停止時でも取得は不要=取得できないだけ) |
| 暗号化 | age 公開鍵のみ | 同じ。**別の age 鍵ペア**(etcd-backup と共有しない)。秘密鍵は Bitwarden + オフライン控えの 2 系統 |
| 保存先 | R2 `etcd-backup` | **Object Lock 対応の S3 互換**(§0)。バックアップ用アカウントは `PutObject` のみで `DeleteObject` / `PutBucketLifecycle` を持たない |
| 世代 | 14 日 + 最新 48 | 全体設計 §9: 6 時間 7 日 / 日次 30 日 / 週次 12 週 / 月次 12 か月。**削除は実行ホストではなく、バケットの Lifecycle ルールに任せる**(Object Lock の保持期間 = 各世代の保持期間。プレフィックス `6h/` `daily/` `weekly/` `monthly/` を分けてロック期間を変える) |
| 実行ホスト | k8s2(control-plane) | **Kubernetes・OpenBao から独立した専用ホスト**。bao ノード自身では動かさない |
| 通知 | textfile のみ | textfile + **外部死活監視(dead-man's switch)**。成功を送り続け、途絶えたら通知される形にする(実行ホストが死んだ場合に気づくため) |

実装上の注意:

- スナップショットは**全 Secret を含む**ため、平文ファイルは `umask 077` の tmpfs に作り、暗号化後に `shred` ではなく**tmpfs ごと破棄**する。
- アップロード後は **HEAD でサイズ検証**し、**別経路(実行ホストと別の場所)から `sha256` を検証**する(全体設計 §4)。
- 追加 Snapshot: アップグレード・大規模変更前に手動で取る `backup.sh --reason pre-upgrade` を用意。
- **「バックアップ専用 Policy は復元権限を持たない」ため、`bao operator raft snapshot restore` は人間の管理者操作に限る**。

### 復旧演習(復元できることの検証)

- 月次の自動復元テスト: 最新の暗号化スナップショットを取得 → 復号(復号鍵は演習時のみオペレーターが提供する。自動化ホストには置かない) → **使い捨ての 1 ノード OpenBao** に restore → Unseal(Shamir 鍵 or 検証用 seal)→ 既知の canary KV を読む・Auth/Policy が存在することを確認。
- 注意: 実運用の Unseal 鍵を自動テストに渡してはいけない。**自動テストは「復号・restore・canary 読み取り」までを検証用 seal で行う設計**(Shamir 鍵が要る完全検証は、四半期の人手の演習で行う)。
- 結果を `docs/openbao-restore.md` の演習記録に追記。RTO の実測値で全体設計 §9 の目標を更新する。

## 8. 監視

| 対象 | シグナル | 備考 |
|---|---|---|
| Seal | `vault_core_unsealed == 0` | **最重要**。1 ノードでも即通知 |
| Raft | leader 不在、voter 数 < 3、`raft.commitTime` 悪化 | 既存 Prometheus に追加 |
| API | health の失敗 | Kubernetes **外**からの probe を必須にする |
| Audit | audit device 書込失敗 | 失敗すると OpenBao が止まるので先に検知 |
| 認証 | `auth` 失敗の急増、token 大量発行 | audit log → Loki のルール |
| Backup | `openbao_backup_*`(最終成功時刻、サイズ、検証結果) | textfile + 外部 dead-man |
| TLS | 証明書期限 14 日前 | |
| ディスク | `/var/lib/openbao` と audit log の使用率 | audit log の肥大は全停止に直結 |

アラートは Kubernetes 内の Alertmanager のみに依存しない(全体設計 §8)。外部の通知経路を 1 本は用意する。

## 9. 本番化前の確認項目(Go / No-Go)

- [ ] 拠点間 RTT / loss を 1 週間以上計測し、Raft のタイムアウトに対して余裕がある(`heartbeat_timeout` / `election_timeout` は計測値を元に調整)。
- [ ] 1 ノード停止・leader 切替・拠点断(1 拠点の WireGuard 遮断)で継続できる。
- [ ] 2 ノード停止後の復旧手順(**クォーラム喪失からの `peers.json` 復旧**)を実際に演習した。
- [ ] 全ノード消失 → スナップショットからの復旧を演習し、RTO を実測した。
- [ ] audit device 障害時の挙動を確認した。
- [ ] Unseal 鍵保管者 5 名・保管先・再配布(rekey)手順が確定している。
- [ ] バックアップ先の Object Lock と、実行アカウントが削除できないことを確認した。

## 10. 未決事項(決めてから該当フェーズへ)

1. **第3拠点のホストと WireGuard 経路**(Phase 1 の着手条件)。
2. **Object Lock 対応の S3 互換ストレージの選定**(R2 不可)。候補: AWS S3 / Backblaze B2 / Wasabi など。費用と、`bws` に置く資格情報の分離(etcd-backup の R2 トークンと別)。
3. ~~OIDC プロバイダ~~ 確定: Google / Microsoft(復旧経路を兼ねる)+ Keycloak(K8s 上、日常利用のみ)。§5 参照。
4. ~~外部 CA~~ 確定: Let's Encrypt + DNS-01(§2 TLS)。残り: API の公開経路(Cloudflare Access / Tunnel)の具体的な構成。DNS-01 のトークンは kigawa.net ゾーンの DNS 編集 + IP 制限(委任は将来)。
5. **Auto Unseal への移行判断**(§6 の手動 Unseal 運用負荷)。
6. **バックアップ専用ホスト**(コストと置き場)。
7. 既存 `bws`(Bitwarden Secrets)から OpenBao へ**何を移すか、何を移さないか**(§1 の循環禁止リスト)。
