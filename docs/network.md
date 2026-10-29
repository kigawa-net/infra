# ネットワーク構成ドキュメント

このドキュメントでは、kigawa-net インフラストラクチャのネットワーク構成について説明します。

> **注記(2026-10-29):** alice は Terraform 上すでに廃止済み(`hardware/alice/` には `.tf` がなく、`.terraform` と `.terraform.lock.hcl` の残骸だけが残っている。`hardware/k8s4/main.tf` に「aliceは廃止済み」の記載がある)。本書の「4. ゲートウェイ (Alice)」節と、構成図・IP 割り当て表の alice に関する記述は廃止前の設計の履歴であり、現行構成は「現行のゲートウェイと VPN」節、[IONOS ゲートウェイ設計書](ionos-gateway-design.md)、[全体ネットワーク・VPN基盤設計書](network-vpn-architecture-design.md) を参照する。

## 概要

本ネットワークは、BGPによる動的ルーティング、VRRP (Keepalived) による高可用性、およびWireGuardによるVPN接続を組み合わせたハイブリッド構成となっています。

## コンポーネント

### 1. BGP ルーティング (FRR)

ネットワーク全体のルーティング制御にBGPを使用しています。コントロールプレーンノード(k8s1, k8s2, k8s4)の BGP は、2026-10-06 に BIRD から FRR へ移行しました(#210)。

- **iBGP フルメッシュ**: Kubernetes コントロールプレーンノード（k8s1, k8s2, k8s4）間でiBGPフルメッシュが構成されています。
    - **ソフトウェア**: [FRR (Free Range Routing)](https://frrouting.org/)(ホストの systemd サービス `frr.service`: zebra + bgpd。apt のパッケージ)
    - **設定ファイルパス**: `/etc/frr/frr.conf`(`hardware/modules/bgp-frr` が生成)
    - **ピアリング設定**: 各ノードの `frr.conf` に、他のコントロールプレーンノードが iBGP の隣接ノードとして定義されています(`next-hop-self`)。
    - **確認**: `vtysh -c 'show bgp ipv4 unicast summary'`、`ip route show proto bgp`
- **AS番号**: `65000` (Inuyama K8s) を主に使用しています。外部ピア(IONOS・Oracle)とは `local-as 65010 no-prepend replace-as` で接続します。
- **iBGP のタイマー**: control-plane 3 台の iBGP は `timers 3 9`(keepalive 3 秒 / hold 9 秒)です(issue #232)。BGP デーモンや OS が止まったノードの経路を、既定(最大 180 秒)ではなく 9 秒で撤回します。外部の eBGP ピアは既定のままです。apiserver だけがハングした場合は、BGP では検知できないため、kube-vip のヘルス連動(後述)が担当します。
- **広告ルート**:
    - **DNS VIP (10.0.0.53)**: 各コントロールプレーンノードが自身の `lo` にこのIPをアサインし、`network` 文でBGP経由で広告します。
    - **直結経路の再配布**: `redistribute connected` を、許可リスト(`redistribute_connected_prefixes`)付きで使います。BIRD の `protocol direct` のように全ての直結経路は流しません。API VIP(`10.0.0.100/32`)とゲートウェイ VIP(`10.0.0.254/32`)は、保持ノードの直結経路として伝搬します。
    - **Kubernetes サービスネットワーク**: kube-vip 等を通じて広告される場合があります。
- **kube-vip との BGP**: 同一ホストの kube-vip と FRR の BGP は張れません(FRR は `127.0.0.x` を BGP の自分側に使えず、自ノードのアドレスを neighbor に指定できず、kube-vip が送る next-hop は自ノードのアドレスのため `martian or self next-hop` で破棄されます)。kube-vip は VIP を保持ノードのインターフェースに付けるだけで、広告は直結経路の再配布が担います。kube-vip の `bgp_peeraddress`(`127.0.0.2`)は、消さずに残します(ピア 0 件だと kube-vip が落ちる)。FRR は接続を拒否するだけで、kube-vip のログに接続エラーが出ます。詳細は `hardware/modules/bgp-frr/README.md`。
- **移行の記録**: `hardware/modules/bgp-frr/RUNBOOK-step2-k8s1.md`(切り替え手順と、k8s1・k8s2・k8s4 の実施結果)。
- **外部ピア(現行)**: IONOS(AS65030)と Oracle(AS65040)と eBGP で接続する。Soichiro は AS65020(`hardware/ionos/variables.tf` の `soichiro_asn`)。詳細は「現行のゲートウェイと VPN」節。
- **Alice Gateway (FRR)(廃止済み)**: かつて `alice` ノードで [FRR (Free Range Routing)](https://frrouting.org/) が動作しています。
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

この `ip name-server` は、**各コントロールプレーンノードの kresd の LAN アドレス**
(`192.168.1.103`(k8s1)、`192.168.1.20`(k8s2)、`192.168.1.120`(k8s4))だけを
指すようにすること。`10.0.0.53`(DNS VIP)は**指定しないこと**。

- **`10.0.0.53` を指定してはいけない理由**: スイッチにとって `10.0.0.0/24` は
  `vlan2` の直結サブネットのため、`10.0.0.53` を ARP で探す。VIP は各ノードの
  `lo` にあり、BGP でクラスタ内に広告されるだけで ARP には答えないため、
  スイッチから届かず、`no DNS response packet ... from 10.0.0.53` が出続けた
  (2026-10-05 判明・修正。#239)。
- 3台の kresd は、内部名(`k8s.kigawa.net` → `10.0.0.100`、`onemc.world` ゾーン)と
  外部名の両方を引ける。1台が落ちても、残りに回る。
- 過去に別の古い内部DNSサーバー(`192.168.1.113` 等)が `ip name-server` に
  残っていたことがあり、それらが `k8s.kigawa.net` 等の古い/誤ったレコード
  (移行前の `192.168.1.x` 系アドレス)を返し続けていたため、`kubectl` や他の
  クラスタ内サービスへの接続が数時間〜半日単位で断続的に失敗する原因になっていた
  (2026-08-12 判明・修正)。古いサーバーを残さないこと。

確認コマンド:
```
show running-config | include name-server
```
上の3つ以外のエントリがある場合は削除すること。端末側の確認は
`dig +short k8s.kigawa.net @192.168.1.1` が `10.0.0.100` を返すこと。

なお、`10.0.0.53` は、スイッチ(`192.168.1.1`)からは使えない。スイッチは `10.0.0.0/24` を `vlan2` の
直結として持ち、`10.0.0.53`(`lo` の anycast VIP)は ARP に答えないため。#241 の Core Router VIP
(`192.168.1.200/24`)ができても、スイッチの経路は変えない(下の 2.5 節)ので、状況は同じ。LAN の機器は、
各ノードの kresd の LAN アドレス(`192.168.1.103` / `.20` / `.120`)を使う。

作業端末など、有線(`192.168.1.1`)と無線(別ルーター)の両方が DefaultRoute の
場合、無線側の DNS が `k8s.kigawa.net` を公開 IP に解決することがある。
`resolvectl domain <有線 IF> ~kigawa.net ~onemc.world` で、内部ドメインを
有線の DNS に固定する。

### 2.5 workerノードから内部ネットワーク(10.0.0.0/24)への経路

workerノードは `192.168.1.0/24` のみに接続され、BGPピアではない(BGP デーモンは動かない)。
そのままではデフォルトゲートウェイ(物理スイッチ `192.168.1.1`)に `10.0.0.0/24` 宛を
送出してしまい到達できない(issue #154 / #193)。DNS VIP `10.0.0.53` や Keycloak/Ingress
VIP `10.0.0.240` に届かず、CoreDNSのforward失敗やadmin-panelのJWKS取得失敗の原因になる。

対策として、全 worker(worker1 / 3 / 4 / 5)に以下の静的経路を入れる。k8s1/k8s2/k8s4 は自宅LAN側にもアドレスを持ち
`ip_forward=1` のため、これらの keepalived(VRRP)が持つ **Core Router VIP(`192.168.1.200`)** を
next-hop にする(#241)。

```
ip route replace 10.0.0.0/24 nexthop via 192.168.1.200 weight 1
```

- **なぜスイッチ(`192.168.1.1`)に任せないか**: スイッチは `10.0.0.0/24` を `vlan2` の直結として持つため、
  サービスの VIP(LoadBalancer の `10.0.0.50`〜`.62`、`.240`〜`.243`、DNS の `10.0.0.53`)に届かない
  (ARP に答えない、またはスイッチの `vlan2` から見えない)。これらは、コントロールプレーンの各ノードが
  ローカルの VIP(`kube-ipvs0` や `lo`)として受け取り、Pod に振り分ける。そのため、コントロールプレーンの
  ノードをゲートウェイにして、`10.0.0.0/24` を渡す。
- **なぜ VIP 1 本か**: 以前は k8s1 / k8s2 / k8s4 の 3 台への ECMP だった。ECMP のハッシュ方式が既定
  (`fib_multipath_hash_policy=0`)のため、あるゲートウェイがダウンすると、そこに振られる通信が常にそこへ
  流れ続け、`no route to host` になった(2026-10-05、k8s2 のダウン中に worker3 が NotReady になった)。
  VRRP の failover(約 1 秒)に任せることで、この固定を無くす。負荷分散はなくなる(MASTER の 1 台に集まる)。

- 定義: `hardware/modules/cluster-route`(Terraform。`k8s-worker1` / `k8s-worker3` / `k8s-worker4` / `k8s-worker5` から利用)
- 自己修復: `cluster-route.timer` が1分ごとに `cluster-route.service` を再実行する
  (`ip route replace` は冪等)。経路が何らかの理由で失われても最大1分で復旧する
  (2026-10-03、経路が失われたままCoreDNSのタイムアウトが約3時間続いた事象への対策)
- 確認コマンド(worker上):
  ```
  ip route get 10.0.0.53          # via 192.168.1.{103,20,120} になること
  systemctl list-timers cluster-route.timer
  dig +short +time=2 +tries=1 @10.0.0.53 kigawa.net
  ```
- `k8s-worker4` も、`hardware/k8s-worker4` から、同じ `cluster-route` モジュール(タイマー付き)で管理する(#193。
  2026-10-16 に、手動設定の経路が消えたまま戻らず、worker4 上の CoreDNS が `10.0.0.53` に届かなくなった)。
- `k8s-worker1` も、`hardware/k8s-worker1` から、同じ `cluster-route` モジュールで管理する(#323)。固定アドレスとデフォルト経路は `modules/static-network` で管理する(#317)。以前は手動設定(`/usr/local/bin/cluster-route.sh`)で、`cluster-route.timer` が無く、経路が消えても自動では復旧しなかった。

### 3. 高可用性 (VRRP / Keepalived / kube-vip)

- **Keepalived (VRRP)**:
    - Terraformモジュール `hardware/modules/keepalived` を通じて管理されます。
    - **VRRP (Virtual Router Redundancy Protocol)** を使用して、特定の物理インターフェース上でVIPを浮動させます。
    - **役割**: 主にゲートウェイや特定のサービスにおけるVIPの冗長化に使用されます。
    - **設定**: `/etc/keepalived/keepalived.conf` にて VRRP インスタンス、優先度（Priority）、仮想ルーターID（Virtual Router ID）、認証パスワード、および管理対象のVIPが定義されます。
    - **VRRP インスタンス**(k8s1 / k8s2 / k8s4 の3台。同じ優先度の順: k8s1=110、k8s2=100、k8s4=90):

      | インスタンス | VRID | VIP | 用途 |
      |---|---|---|---|
      | `VI_1` | 1 | `10.0.0.254/32` | 内部(`10.0.0.0/24`)側のゲートウェイ VIP |
      | `VI_CORE` | 2 | `192.168.1.200/24` | **Core Router VIP**(#241)。LAN(`192.168.1.0/24`)側の仮想コアルーターの next-hop。worker の `10.0.0.0/24` 宛の経路(2.5 節)が使う |

    - **Core Router VIP のヘルスチェック**: `/etc/keepalived/check-core-router.sh`(IP 転送が有効で、BGP が `:179` で待ち受け中で、kube-proxy が `http://127.0.0.1:10256/healthz` に 200 を返す)。失敗すると、`VI_CORE` の優先度が 30 下がり(`weight -30`)、別のノードに VIP が移る。`vrrp_script` には `enable_script_security` が必要で、`VI_CORE` があるときだけ `global_defs` で有効にしている。kube-proxy を見るのは、worker の `10.0.0.0/24` 宛の通信が、この VIP の MASTER 1 台に集まり、サービスの VIP(`kube-ipvs0` / `lo`)の振り分けを kube-proxy に頼っているため(#252)。`interval 2` / `fall 2` なので、2 回連続(約 4 秒)で失敗すると、優先度が下がる。
    - **failover**: MASTER の keepalived を止めると、約1秒で、別のノードが MASTER になる(2026-10-06 の試験。worker3 から DNS・API へ 0.3 秒間隔で 224 回アクセスして、失敗 0 回)。突然ノードが落ちた場合は、`advert_int` の3倍(約3秒)で引き継ぐ想定(未試験)。
    - **設定の反映**: `systemctl reload-or-restart keepalived`(reload を優先する。既存の `VI_1` の VIP は、reload では外れない)。
    - **確認**:
      ```
      ip -4 addr show | grep -E "192\.168\.1\.200|10\.0\.0\.254"   # MASTER のノードだけに出る
      journalctl -u keepalived --since "-10min" | grep -E "VI_CORE|VI_1|chk_core"
      ```
- **kube-vip**:
    - Kubernetes コントロールプレーンのAPIサーバー VIP (例: 10.0.0.100) を管理します。
    - **BGPモード**: 本環境ではBGPモードを推奨し、ARPモードは利用しません。これにより、レイヤー2の制限を受けずに柔軟なルーティングが可能になります。
    - 各コントロールプレーンノード上でスタティックポッドとして動作し、APIサーバーの可用性を担保します。
    - **ヘルス連動(issue #232)**: 各 CP ノードの systemd timer(`kube-vip-health.timer`、10 秒間隔)が、ローカルの `https://127.0.0.1:6443/livez?exclude=etcd` を確認します。3 回連続で失敗し、**かつ他の control-plane の apiserver(`kube_vip_health_peers`)が 1 つでも健全なとき**に限り、`/etc/kubernetes/manifests/kube-vip.yaml` を `/var/lib/kube-vip-health/` へ退避して kube-vip を止め、VIP を外します(別ノードが引き継ぎます)。他に健全な apiserver が無いとき(全ノードが同時に不調、`kube_vip_health_peers` が空)は、VIP の持ち主がいなくならないよう、止めません。6 回連続で成功すると、マニフェストを戻します。`kube_vip_enabled=false`(Terraform が kube-vip を意図的に外したノード)では、何もせず、退避したコピーも戻しません。OS ごと止まった場合は動かないため、BGP の hold timer が頼りです。`livez` で etcd を除外しているのは、etcd の quorum を失ったときに、etcd だけが理由で止めないためです。
      ```bash
      systemctl list-timers kube-vip-health.timer
      journalctl -t kube-vip-health --since "-1h"
      ls /var/lib/kube-vip-health/   # kube-vip.yaml があれば退避中
      ```
    - 自動適用: `hardware/modules/kube-vip` を変更して main にマージすると、GitHub Actions(`terraform.yml`)が利用元(k8s1・k8s2・k8s4)を 1 台ずつ apply します(`max-parallel: 1`、`fail-fast` なし)。
    - テスト: `bash hardware/modules/kube-vip/test-kube-vip-health.sh`(偽の curl / ip を使い、実機には触れません)。

### 4. 現行のゲートウェイと VPN

alice 廃止後の現行構成(値は各 `hardware/*/variables.tf` の既定値。実機の状態は未確認)。詳細は [IONOS ゲートウェイ設計書](ionos-gateway-design.md) と [全体ネットワーク・VPN基盤設計書](network-vpn-architecture-design.md)。

- **WireGuard(IONOS hub)**: `172.31.254.0/24`。ionos(`74.208.55.86`、`172.31.254.2`)が hub。k8s1 は `172.31.254.11`、k8s2 は `172.31.254.12`、k8s4 は `172.31.254.1`。bao-02 は `.30`、bao-03 は `.31`。
- **WireGuard(IONOS 専用リンク、#238)**: ionos ↔ k8s4 が `172.31.252.0/30`(IONOS 側 `.1`・`wg-gw4`、k8s4 側 `.2`・`wg-ionos-gw`、ポート 51821、BGP の `local_pref` 200)で主。ionos ↔ k8s2 が `172.31.252.4/30`(IONOS 側 `.5`・`wg-gw2`、k8s2 側 `.6`・`wg-ionos`、ポート 51822、`local_pref` 150)で予備。
- **WireGuard(Oracle)**: k8s4 の `wg-oracle`(`172.31.253.0/24`、k8s4 が `.1`)。
- **EasyTier Overlay**: `10.250.0.0/24`(network 名 `kigawa-net`、v2.6.4、11010)。WireGuard・FRR とは別に並行稼働する。下表のとおり。

  | ノード | Overlay IP | `easytier_enabled` の既定 |
  |---|---|---|
  | bao-02(ServerCheap) | `10.250.0.1` | true |
  | ionos | `10.250.0.2` | true |
  | k8s4(Inuyama Gateway) | `10.250.0.11` | true(#395) |
  | k8s1 | `10.250.0.12` | **false**(未有効化) |
  | k8s2 | `10.250.0.13` | true(#400) |
  | bao-03 | `10.250.0.31` | true |

  k8s4・k8s2 は有効化済みだが、NAT 配下からの接続の実測は未実施([設計書 §4.1.1](network-vpn-architecture-design.md))。

### 4.1 旧ゲートウェイ (Alice)(廃止済み・履歴)

廃止前、`alice` ノードは、ネットワークの境界ゲートウェイとして以下の機能を果たしていました。

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

> 次の2つの図(1. 物理・論理トポロジー、2. BGP ピアリング構成)は廃止前の alice を含む構成の履歴。現行の外部接続は上の「現行のゲートウェイと VPN」節を参照する。

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
            worker3[k8s-worker3<br/>192.168.1.130]
            worker5[k8s-worker5<br/>192.168.1.150]
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
| 10.0.0.53 | DNS VIP | FRR (BGP広告) | VIP |
| 10.0.0.100 | K8s API VIP | kube-vip | CP (VIP) |
| 10.0.0.103 | k8s1 (Node) | 静的割当 | CP (Node) |
| 10.0.0.120 | k8s2 (Node) | 静的割当 | CP (Node) |
| 10.0.0.140 | k8s4 (Node) | 静的割当 | CP (Node) |
| 192.168.1.228 | k8s-worker1 | 静的割当(`modules/static-network`) | Worker。旧 DHCP アドレス 192.168.1.105 も残してあり、.228 が消えている間の SSH 接続先(`static_network_ssh_host`)になる |
| 192.168.1.130 | k8s-worker3 | 静的割当 | Worker |
| 192.168.1.121 | k8s-worker4 | 手動設定(IaC は `cluster-route` のみ。アドレスは IaC 管理外) | Worker |
| 192.168.1.150 | k8s-worker5 | 静的割当 | Worker |
| 192.168.1.200 | Core Router VIP | Keepalived (VRRP) | ゲートウェイ |
| 10.0.0.240 | Ingress VIP | kube-vip / BGP | VIP |
| 10.0.0.241 | Minecraft VIP | kube-vip / BGP | VIP |
| 74.208.55.86 | IONOS Gateway (Public) | 静的割当 | IONOS |
| 172.31.254.2/24 | IONOS Gateway (WG hub) | WireGuard | IONOS |
| 10.250.0.0/24 | EasyTier Overlay | EasyTier | Overlay |
| 161.248.62.66 | Alice Gateway (Public、廃止済み) | 静的割当 | Alice |
| 172.31.255.2/24 | Alice Gateway (WG、廃止済み) | WireGuard | Alice |
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
