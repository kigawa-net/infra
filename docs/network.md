# ネットワーク構成ドキュメント

このドキュメントでは、kigawa-net インフラストラクチャのネットワーク構成について説明します。

## 概要

本ネットワークは、BGPによる動的ルーティング、VRRP (Keepalived) による高可用性、およびWireGuardによるVPN接続を組み合わせたハイブリッド構成となっています。

## コンポーネント

### 1. BGP ルーティング (Bird / FRR)

ネットワーク全体のルーティング制御にBGPを使用しています。

- **iBGP フルメッシュ**: Kubernetes コントロールプレーンノード（k8s1, k8s2, k8s4）間でiBGPフルメッシュが構成されています。
    - **ソフトウェア**: [Bird2](https://bird.network.cz/)
    - **設定ファイルパス**: `/etc/bird/bird.conf`
    - **ピアリング設定**: 各ノードの `bird.conf` に、他のコントロールプレーンノードが隣接ノードとして定義されています。
- **AS番号**: `65000` (Inuyama K8s) を主に使用しています。
- **広告ルート**:
    - **DNS VIP (10.0.0.53)**: 各コントロールプレーンノードが自身にこのIPをアサインし、BGP経由で広告します。
    - **Kubernetes サービスネットワーク**: kube-vip 等を通じて広告される場合があります。
- **Alice Gateway (FRR)**: `alice` ノードで [FRR (Free Range Routing)](https://frrouting.org/) が動作しています。
    - **役割**: 外部ピアとの接続、OSPFによる内部ルートの学習、WireGuardインターフェース経由のルーティング。

### 2. DNS インフラストラクチャ

高可用なDNSリゾルバーサービスを提供しています。

- **DNS VIP**: `10.0.0.53`
    - このIPはBGPによってネットワーク全体に広告され、Anycastのように最も近い（またはECMPによって分散された）ノードがリクエストを処理します。
- **Knot Resolver (kresd)**:
    - 各コントロールプレーンノードでコンテナまたはサービスとして動作。
    - `/etc/knot-resolver/kresd.conf` にて、`0.0.0.0` および `DNS VIP (10.0.0.53)` で Listen するよう設定されています。
- **Knot DNS (Authority)**:
    - 権威DNSサーバーとして動作。
    - 管理ゾーン: `kigawa.net`, `onemc.world`
    - ゾーンファイルは `hardware/zones/` 下で管理されています。

**重要: LANスイッチ(AT-x510-28GTX, `192.168.1.1`)のDNS中継設定**

`192.168.1.0/24` LAN上の一般クライアント(ワークステーション等)は、DHCPで
配布されるデフォルトのネームサーバーとしてこのスイッチ(`192.168.1.1`/
`10.0.0.1`)を使うことが多い。スイッチは `ip dns forwarding` (簡易DNS中継、
ドメイン別のオーバーライドやキャッシュ制御はできない) で `ip name-server`
に設定した上位DNSへ単純に問い合わせを転送するだけの機能しかない。

この `ip name-server` は必ず `10.0.0.53`(上記DNS VIP)のみを指すように
すること。過去に別の古い内部DNSサーバー(`192.168.1.113` 等)が
`ip name-server` に残っていたことがあり、それらが `k8s.kigawa.net` 等の
古い/誤ったレコード(移行前の `192.168.1.x` 系アドレス)を返し続けて
いたため、`kubectl` や他のクラスタ内サービスへの接続が数時間〜半日単位で
断続的に失敗する原因になっていた(2026-08-12 判明・修正)。

確認コマンド:
```
show running-config | include name-server
```
`10.0.0.53` 以外のエントリがある場合は削除し、`10.0.0.53` のみにすること。

### 3. 高可用性 (VRRP / Keepalived / kube-vip)

- **Keepalived (VRRP)**:
    - Terraformモジュール `hardware/modules/keepalived` を通じて管理されます。
    - **VRRP (Virtual Router Redundancy Protocol)** を使用して、特定の物理インターフェース上でVIPを浮動させます。
    - **役割**: 主にゲートウェイや特定のサービスにおけるVIPの冗長化に使用されます。
    - **設定**: `/etc/keepalived/keepalived.conf` にて VRRP インスタンス、優先度（Priority）、仮想ルーターID（Virtual Router ID）、認証パスワード、および管理対象のVIPが定義されます。
- **kube-vip**:
    - Kubernetes コントロールプレーンのAPIサーバー VIP (例: 10.0.0.100) を管理します。
    - **BGPモード**: 本環境ではBGPモードを推奨し、ARPモードは利用しません。これにより、レイヤー2の制限を受けずに柔軟なルーティングが可能になります。
    - 各コントロールプレーンノード上でスタティックポッドとして動作し、APIサーバーの可用性を担保します。

### 4. ゲートウェイ (Alice)

`alice` ノードは、ネットワークの境界ゲートウェイとして以下の機能を果たします。

- **FRR**:
    - BGP/OSPFによるルーティング制御。
    - 外部ネットワークへのルート集約や、内部ネットワークへのデフォルトルートの配布などを行います。
- **HAProxy**:
    - 外部（インターネット）からのリバースプロキシとして動作。
    - SSL終端を行い、バックエンドの各サービス（Kubernetes Ingressなど）にトラフィックを振り分けます。
- **WireGuard**:
    - `wg0` インターフェースを使用し、外部拠点やモバイルクライアントとのセキュアな通信路を提供します。
    - WireGuardネットワーク内のルーティングはFRRによって管理される場合があります。
    - **ピア構成** (`172.31.255.0/24`):
        - Inuyama サイトゲートウェイ (`172.31.255.1`) — eBGP 接続、LAN (`192.168.1.0/24`) へのルーティング
        - k8s1 (`172.31.255.11`) — 直接ピア
        - k8s2 (`172.31.255.12`) — 直接ピア

## ネットワーク構成図

### 1. 物理・論理トポロジー

```mermaid
graph TB
    subgraph "External / Remote"
        Inuyama[Inuyama Site<br/>172.31.255.1<br/>AS 65010]
        Internet((Internet))
    end

    subgraph "Alice Gateway (Cloud)"
        Alice[Alice Gateway<br/>161.248.62.66<br/>AS 65020]
        HAProxy[HAProxy<br/>SSL Termination]
        FRR[FRR<br/>BGP/OSPF]
        Alice --- HAProxy
        Alice --- FRR
    end

    subgraph "Inuyama Site (10.0.0.0/24)"
        subgraph "Inuyama K8s (AS 65000)"
            k8s1[k8s1<br/>10.0.0.103]
            k8s2[k8s2<br/>10.0.0.120]
            k8s4[k8s4<br/>10.0.0.140]
        end

        subgraph "Kubernetes Workers"
            worker3[k8s-worker3<br/>10.0.0.30]
            worker5[k8s-worker5<br/>10.0.0.40]
        end

        Router[Physical Router<br/>10.0.0.1]
    end

    %% Connections
    Internet <--> Alice
    Inuyama <-- "WireGuard (wg0)<br/>172.31.255.0/24" --> Alice
    k8s1 <-- "WireGuard (wg0)<br/>172.31.255.11" --> Alice
    k8s2 <-- "WireGuard (wg0)<br/>172.31.255.12" --> Alice
    Alice <--> Router
    Router <--> k8s1
    Router <--> k8s2
    Router <--> k8s4
    Router <--> worker3
    Router <--> worker5
    Router <--> worker_other

    %% VIPs
    k8s1 -.-> VIP_DNS[DNS VIP<br/>10.0.0.53]
    k8s2 -.-> VIP_DNS
    k8s4 -.-> VIP_DNS

    k8s1 -.-> VIP_K8S[K8s API VIP<br/>10.0.0.100]
    k8s2 -.-> VIP_K8S
    k8s4 -.-> VIP_K8S

    k8s1 -.-> VIP_GW[Gateway VIP<br/>10.0.0.254]
    k8s2 -.-> VIP_GW
    k8s4 -.-> VIP_GW
```

### 2. BGP ピアリング構成

```mermaid
graph LR
    subgraph "AS 65000 (Inuyama K8s)"
        k8s1 <--> k8s2
        k8s2 <--> k8s4
        k8s4 <--> k8s1
    end

    subgraph "AS 65020 (Alice)"
        Alice
    end

    subgraph "AS 65010 (Inuyama)"
        Inuyama
    end

    Alice <-- "eBGP<br/>WireGuard" --> Inuyama
    k8s4 -. "Optional / Future" .-> Alice
```

## IPアドレス設計

Inuyamaサイト（`10.0.0.0/24`）では、管理の容易性と将来の拡張性を確保するため、以下のサブネットポリシーに基づいてIPアドレスを割り当てています。また、既存の `192.168.1.0/24` も管理用として維持されます。

### 1. サブネットポリシー

| IPレンジ | 用途 | 備考 |
|----------|------|------|
| `10.0.0.1` - `.9` | 物理インフラ / ネットワーク機器 | ルーター、スイッチ等 |
| `10.0.0.10` - `.49` | K8s Worker ノード | ワーカーノード物理IP |
| `10.0.0.50` - `.69` | ネットワークサービス VIP | DNS VIP (`10.0.0.53`) 等 |
| `10.0.0.100` - `.149` | K8s Control Plane ノード | ノード物理IP, API VIP |
| `10.0.0.150` - `.199` | 固定IPデバイス / 管理用ホスト | 監視、ストレージ等 |
| `10.0.0.200` - `.249` | サービス VIP | Ingress VIP, Minecraft VIP 等 |
| `10.0.0.250` - `.254` | ゲートウェイ VIP | デフォルトゲートウェイ (`10.0.0.254`) 等 |
| `192.168.1.0/24` | 管理用 / 旧ネットワーク | 既存デバイス、管理インターフェース |

### 2. 具体的なIP割り当て一覧

| IPアドレス | ホスト / 用途 | 管理方法 | カテゴリ |
|-----------|--------------|----------|----------|
| 10.0.0.1 | 物理ルーター | 静的割当 | インフラ |
| 10.0.0.254 | デフォルトゲートウェイ VIP | Keepalived (VRRP) | ゲートウェイ |
| 10.0.0.53 | DNS VIP | Bird (BGP広告) | VIP |
| 10.0.0.100 | K8s API VIP | kube-vip | CP (VIP) |
| 10.0.0.103 | k8s1 (Node) | 静的割当 | CP (Node) |
| 10.0.0.120 | k8s2 (Node) | 静的割当 | CP (Node) |
| 10.0.0.140 | k8s4 (Node) | 静的割当 | CP (Node) |
| 10.0.0.30 | k8s-worker3 | 静的割当 | Worker |
| 10.0.0.40 | k8s-worker5 | 静的割当 | Worker |
| 10.0.0.240 | Ingress VIP | kube-vip / BGP | VIP |
| 10.0.0.241 | Minecraft VIP | kube-vip / BGP | VIP |
| 161.248.62.66 | Alice Gateway (Public) | 静的割当 | Alice |
| 172.31.255.2/24 | Alice Gateway (WG) | WireGuard | Alice |
| 172.31.255.1 | Inuyama Gateway (WG) | WireGuard | Inuyama |
| 172.31.255.11 | k8s1 (WG) | WireGuard | Inuyama |
| 172.31.255.12 | k8s2 (WG) | WireGuard | Inuyama |
| 10.244.0.0/16 | Pod ネットワーク | Flannel | K8s Internal |
| 10.96.0.0/12 | Service ネットワーク | Kubernetes | K8s Internal |
| 192.168.1.103 | k8s1 (旧IP/管理) | 静的割当 | 管理 |
| 192.168.1.20 | k8s2 (旧IP/管理) | 静的割当 | 管理 |
| 192.168.1.120 | k8s4 (旧IP/管理) | 静的割当 | 管理 |
| 192.168.1.253 | main (作業用ホスト) | 静的割当 | 管理 |
| 192.168.1.254 | 旧ゲートウェイ | 静的割当 | 管理 |
