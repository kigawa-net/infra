# kigawa-net 全体ネットワーク・VPN基盤設計 v1.0

基本方針：EasyTier を NAT Traversal と拠点間 P2P の基盤とし、ServerCheap・IONOS を公開中継ノードとして冗長化します。既存の WireGuard + FRR/BGP は移行期間中維持し、Keycloak・OpenBao・Kubernetes・管理端末を含めて統合します。

今回の設計では、alice は廃止対象、ServerCheap は新設対象とします。

> これは目標アーキテクチャであり、ServerCheap 移行や EasyTier 導入が既に完了していることを意味しません。既存の WireGuard・FRR・Kubernetes・CI/CD を保護しながら段階移行する設計です。

## 1. 全体アーキテクチャ

```mermaid
flowchart LR
  subgraph Admin[管理端末]
    PC[PC / Android / SSH]
  end
  subgraph Common[共通基盤]
    KC[Keycloak<br/>OIDC / MFA]
    OB[OpenBao<br/>Secrets / PKI]
    MON[Prometheus / Grafana<br/>監視]
    IAC[GitHub / Terraform<br/>IaC]
  end
  subgraph NAT[NAT 配下の拠点]
    INU[Inuyama<br/>EasyTier / FRR<br/>Kubernetes]
    SOI[Soichiro<br/>EasyTier / FRR<br/>LAN 未確定]
  end
  subgraph Pub[公開インフラ]
    SC[ServerCheap<br/>EasyTier / Relay<br/>WireGuard / FRR]
    IO[IONOS<br/>EasyTier / Relay<br/>WireGuard / FRR]
  end
  INU <-->|Direct P2P| SOI
  INU --- SC
  INU --- IO
  SOI --- SC
  SOI --- IO
  SC <--> IO
  PC -->|管理用VPN| SC
  PC -->|管理用VPN| IO
```

拠点間のデータプレーンを EasyTier で統一する方向とします。管理端末は EasyTier クライアントを使用する案と、Headscale を併用する案の両方を残します。運用の単純さを優先するなら EasyTier 統一、Keycloak OIDC と端末単位 ACL を重視するなら Headscale 併用が適します。

## 2. 各拠点の役割

| 拠点 | 接続条件 | 役割 | HA方針 |
| --- | --- | --- | --- |
| ServerCheap | 公開IP想定 | EasyTier公開Peer、Relay、WireGuard、FRR | IONOSで代替 |
| IONOS | 公開IP | EasyTier公開Peer、Relay、WireGuard、FRR | ServerCheapで代替 |
| Inuyama | NAT配下 | Kubernetes、FRR、EasyTier、主要サービス | 公開2拠点へ接続 |
| Soichiro | 通常NAT | EasyTier、FRR、将来のLAN接続 | 公開2拠点へ接続 |
| 管理端末 | 任意のNAT | VPN経由のSSH・管理アクセス | 公開2拠点を利用 |

ServerCheap・IONOS は、できるだけアプリケーションや認証基盤の本体を配置せず、軽量なネットワーク中継・障害時アクセス用ノードとして運用します。

## 3. ネットワーク分離

| ネットワーク | CIDR案 | 用途 |
| --- | --- | --- |
| Inuyama LAN | `10.0.0.0/24` | 既存サーバー |
| Inuyama管理LAN | `192.168.1.0/24` | 既存管理ネットワーク |
| Soichiro LAN | 未確定 | 将来の拠点LAN |
| EasyTier Overlay | `10.250.0.0/24` | P2P・Relay |
| 既存WireGuard | `172.31.254.0/24` | IONOS側 |
| 旧alice WireGuard | `172.31.255.0/24` | ServerCheapへ移行検討 |
| P2P試験用 | `172.31.253.0/30` | 独立試験 |
| Kubernetes Pod | `10.244.0.0/16` | 既存Flannel |
| Kubernetes Service | `10.96.0.0/12` | 既存Service |

注意：`10.250.0.0/24` は既存の Kubernetes Service CIDR `10.96.0.0/12` の範囲外ですが、将来のネットワークとの重複確認は必要です。

Soichiro の LAN CIDR が決まるまでは、Overlay IP 同士の通信のみを有効にします。

## 4. VPN・ルーティングの詳細設計

### 4.1 EasyTier：拠点間P2PとNAT越え

EasyTier の役割は次の3つです。

1. NAT配下のノードを相互発見する。
2. UDP Hole Punching による直接 P2P を試行する。
3. 直接接続できない場合に公開ノード経由で Relay する。

初期 Overlay アドレス案：

| ノード | Overlay IP |
| --- | --- |
| ServerCheap | `10.250.0.1` |
| IONOS | `10.250.0.2` |
| Inuyama Gateway | `10.250.0.11` |
| Soichiro Gateway | `10.250.0.21` |

両公開ノードを初期接続先として登録し、特定の1台だけに依存しない構成にします。

ただし、EasyTier の Relay 切替と直接 P2P への復帰は、採用バージョンで実測する必要があります。

採用バージョン(2026-10-28 決定): **v2.6.4**(2026-05-12 公開)。GitHub の latest(prerelease でない最新)であり、v2.7.0 は prerelease のため採用しない。v2.7.0 は dev でのみ検証対象とする。配布 zip の SHA-256(自分でダウンロードして計算し、GitHub の digest とも一致を確認した値):

| アーキテクチャ | SHA-256 |
| --- | --- |
| x86_64 | `61b659eaedba658fa66fe47d17e1426cdd77e5d02fa15fed447bb4357c09dfd6` |
| aarch64 | `f533ec25a7ea714e09f645615012200278058525795cc3bb690ff011aec1a70f` |

### 4.2 FRR/BGP：拠点間経路制御

既存リポジトリでは、Kubernetes コントロールプレーンの BGP は 2026年10月6日に BIRD から FRR へ移行しています。したがって、FRR を標準ルーティングデーモンとして継続します。

| AS番号 | 用途 |
| --- | --- |
| AS65000 | Inuyama Kubernetes内部 |
| AS65010 | Inuyama外部接続用 |
| AS65020 | ServerCheapへの移管候補(旧 alice が使用していた AS) |
| AS65030 | IONOS |
| AS65040 | Soichiro新規提案 |

Inuyama 側の `local-as 65010 no-prepend replace-as` を考慮し、既存 iBGP フルメッシュに変更を加えないことを原則とします。

### 4.3 EasyTierとBGPの責任分界

ここが設計上、最も重要です。

- FRR / BGP：どの拠点へ転送するか
- EasyTier：P2P か Relay か

推奨するのは、EasyTier をひとつの論理的な転送ネットワークとして FRR へ見せる方式です。

FRR は EasyTier 内部の Direct P2P・Relay 切替に直接介入せず、EasyTier 側で接続経路を最適化します。

ただし、EasyTier で Peer が到達可能なまま Relay へ切り替わった場合、BGP はその経路を Down と認識しません。これは意図した動作です。Relay 時の遅延増加を監視し、必要に応じて別の WireGuard 経路へ切り替えるポリシーを検討します。

## 5. 公開ゲートウェイのHA

ServerCheap と IONOS は別プロバイダーに配置し、単一事業者障害を避けます。

| 機能 | ServerCheap | IONOS |
| --- | --- | --- |
| EasyTier公開Peer | 有効 | 有効 |
| EasyTier Relay | 有効 | 有効 |
| WireGuard | 移行後有効 | 既存維持 |
| FRR | 有効 | 既存維持 |
| HAProxy | 旧aliceから移行 | 既存維持 |
| Prometheus Exporter | 有効 | 有効 |
| OpenBao本体 | bao-02 として配置(例外、下記) | 原則配置しない |

**ServerCheap の実体は `hardware/bao-02`(`207.231.111.196`)です(2026-10-28 確認)。** bao-02 は OpenBao の raft voter 2 台目でもあるため、「公開ゲートウェイに OpenBao 本体は原則配置しない」方針の例外とします(bao-01 は K8s 上の StatefulSet。`docs/openbao-implementation-design.md` §2)。同居のリスクとして、OpenBao の障害や保守が EasyTier の公開 Peer に波及しうること、逆に公開 Peer 側の負荷・侵害が OpenBao に及びうることがあります。OpenBao は WireGuard(`wg0`)上の 8200/8201 だけで待ち受け、EasyTier は 11010 だけを公開するので、待ち受けは分離されています。公開 Peer の負荷が OpenBao に影響する兆候が出たら、ServerCheap を別 VPS に分けることを検討します。

公開サービスの HTTP/HTTPS・Minecraft などの転送は、EasyTier の Relay HA とは別に設計します。

DNS フェイルオーバーは即時切替を保証しないため、HAProxy のヘルスチェック、DNS TTL、クライアント側の接続挙動を含めて検証します。

## 6. Kubernetes・認証・Secret基盤

### Kubernetes

既存の prod/stg/dev 分離を維持します。

- prod：本番サービスと共通基盤を冗長化
- stg：本番変更前の統合試験
- dev：新機能・EasyTier 経路連携の検証

Kubernetes の Pod ネットワークを EasyTier へ直接広告することは初期段階では行いません。拠点間に公開するのは、必要な管理 IP とサービス VIP に限定します。

既存の Keepalived、kube-vip、Core Router VIP `192.168.1.200` の動作は維持します。

### Keycloak

Keycloak は管理者認証の中心としますが、EasyTier そのものに Keycloak OIDC 認証が標準搭載されている前提にはしません。

Keycloak で管理ポータルを認証し、承認された端末に対して EasyTier 設定を配布するプロビジョニング層を設けます。

### OpenBao

OpenBao は EasyTier のネットワーク Secret、WireGuard 秘密鍵、管理用 API 認証情報などを管理します。

- 初期ブートストラップは既存の Bitwarden Secrets Manager を利用
- OpenBao 移行後は Secret 取得と ESO を併用
- 起動時に OpenBao へ接続できなくても既存 VPN が動作するよう、権限を制限したローカル設定を保持
- Secret ローテーションは全 Peer の移行手順を伴う計画作業とする

OpenBao の停止を理由に、稼働中の VPN を停止させない構成にします。

## 7. セキュリティ

| 項目 | 方針 |
| --- | --- |
| EasyTier | ネットワークSecretとPeer認証を使用 |
| WireGuard | Peer単位の公開鍵認証 |
| BGP | Overlay内のみTCP/179を許可 |
| 管理SSH | 管理端末・管理ネットワークからのみ |
| 公開ゲートウェイ | 必要なUDP/TCPポートだけ開放 |
| LANアクセス | Prefix AllowlistとFirewall |
| prod/stg/dev | 経路とアクセス権を分離 |
| Secret | OpenBao管理、Gitへの平文登録禁止 |
| 監査 | SSH、認証、設定変更、Secret取得を記録 |

特に、EasyTier に接続できることと Inuyama の LAN 全体にアクセスできることを同義にしません。

Soichiro からのアクセスも、許可されたサービス・管理 IP に限定します。

## 8. 監視・障害検知

既存の Prometheus・Grafana・Shumoku を拡張します。

| 監視対象 | 指標 |
| --- | --- |
| EasyTier | Peer接続状態、Direct/Relay、RTT |
| ServerCheap | CPU、RAM、ネットワーク、サービス |
| IONOS | 同上 |
| WireGuard | Handshake age、転送量 |
| FRR | BGPセッション、受信Prefix、経路変化 |
| Kubernetes | Node、API、DNS、Ingress |
| OpenBao | Raft quorum、Seal状態、Secret取得 |
| Keycloak | 認証成功率、HTTP応答、DB状態 |
| 公開サービス | 外部からのHTTP/TCP到達性 |

EasyTier の状態取得方法は、固定するバージョンの CLI/API を確認して Exporter を実装します。

## 9. aliceからServerCheapへの移行

> **現状(2026-10-27 時点):** alice は Terraform 上すでに廃止済みです(`hardware/alice/` は存在せず、`hardware/k8s4/main.tf` に「aliceは廃止済み」の記載があります)。現行の WireGuard は IONOS 側(`172.31.254.0/24`)です。以下の手順のうち、alice 側の WireGuard・FRR の撤去は完了済みとして扱い、残作業は DNS・監視・CI/CD・ドキュメントの参照と、alice 実体 VPS の停止状況の確認です。

既存リポジトリを確認したところ、`docs/network.md` と `docs/wireguard-network-map-design.md` では alice 側の WireGuard 接続構成に差があります。後者は alice–k8s4 の単一リンクを現状として扱っています。

そのため、設計書の記載だけを根拠に既存トンネルを削除してはいけません。

また、IONOS 経由で GitHub-hosted Actions から worker3・worker5 へ SSH する専用経路が存在します。この経路は移行中も維持します。

1. 現状調査 — WireGuard Peer、FRR Neighbor、HAProxy、Firewall、CI/CD 依存を確認
2. ServerCheap 構築 — Terraform、OS Hardening、EasyTier、WireGuard、FRR、監視を導入
3. EasyTier 並行稼働 — ServerCheap・IONOS・Inuyama・Soichiro の4ノード Mesh を検証
4. 経路移行 — ServerCheap への BGP 接続と公開サービス転送を段階的に切替
5. 障害試験 — 公開ノード停止、NAT 再起動、Relay 切替、BGP 収束を確認
6. alice 廃止 — DNS、CI/CD、監視、Secret、Terraform 参照を削除してから VPS 停止

## 10. 実装ロードマップ

| 優先度 | 実装対象 | 完了条件 |
| --- | --- | --- |
| P0 | ServerCheapの基盤構築 | SSH・Firewall・監視が正常 |
| P0 | EasyTier 4ノードMesh | 全Peer疎通、NAT越え確認 |
| P0 | 公開ノードHA | 片系停止時も拠点間通信可能 |
| P1 | FRR/BGP統合 | 許可Prefixのみ広告・学習 |
| P1 | 公開サービス移行 | aliceなしで外部アクセス可能 |
| P1 | alice廃止 | 依存関係ゼロを確認 |
| P2 | Keycloak統合 | 承認済み端末だけ構成取得 |
| P2 | OpenBao統合 | Secret配布・ローテーション検証 |
| P2 | 監視拡充 | P2P/Relay/HAの状態を可視化 |

## 11. 未確定事項

本番実装前に確定する必要があるのは、次の点です。

1. ServerCheap(bao-02)の OS・VPS スペック(グローバル IP は `207.231.111.196` で確定)
2. Soichiro の LAN CIDR
3. 管理端末を EasyTier へ統一するか、Headscale を併用するか
4. ServerCheap 用 WireGuard のサブネット(旧 alice の `172.31.255.0/24` を再利用するか、新規に割り当てるか)
5. 旧 alice の実体 VPS の停止状況、および DNS・監視・CI/CD に残る alice 参照

最終的な推奨構成は、EasyTier による P2P/Relay、FRR による拠点間ルーティング、ServerCheap + IONOS の公開2拠点 HA、Keycloak による管理者認証、OpenBao による Secret 管理です。
