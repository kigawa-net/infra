# kigawa-net/infra 拠点ゲートウェイ設計書

**対象リポジトリ:** `kigawa-net/infra`
**対象拠点:** `inuyama` / `alice`
**設計方針:** 既存Kubernetesは `inuyama` に集約し、`alice` は1ホストの公開ゲートウェイとして利用する。

---

## 1. 概要

### 1.1 目的

`inuyama` に配置済みのKubernetesクラスタを維持しつつ、`alice` を外部公開用ゲートウェイとして追加する。

`alice` は Kubernetes ノードにはせず、以下の役割を1ホストで担う。

```text
alice-01
  - WireGuard endpoint
  - 内部BGP router
  - Load Balancer
  - Public gateway
```

### 1.2 公開ポート

`alice` の外部公開ポートは以下とする。

|    Port | Protocol | 用途                       |
| ------: | -------- | -------------------------- |
| `25565` | TCP      | Minecraft / game service   |
|    `80` | TCP      | HTTP                       |
|   `443` | TCP      | HTTPS                      |
| `51820` | UDP      | WireGuard                  |

BGP `179/tcp` は外部公開しない。
BGP peer は WireGuard 内部のみで張る。

---

## 2. 既存インフラ前提

`kigawa-net/infra` の既存構成に合わせる。

| 項目                   | 既存値                    |
| ---------------------- | ------------------------- |
| Kubernetes拠点         | `inuyama`                 |
| control-plane / etcd   | `k8s1`, `k8s2`, `k8s4`    |
| Kubernetes API VIP     | `192.168.1.100`           |
| 既存HAProxy            | `192.168.1.104`           |
| kube-vip               | static Pod                |
| alice                  | Kubernetesなし、1ホスト   |

既存の重要方針として、Kubernetes API の利用者向け endpoint は VIP `192.168.1.100` を正とする。

kube-vip 自身の leader election 用 API 参照先は、VIP 喪失時の自己参照デッドロックを避けるため、既存 HAProxy `192.168.1.104` または正常な control-plane を使う。

```text
Kubernetes API endpoint:
  192.168.1.100:6443

kube-vip leader election API endpoint:
  192.168.1.104:6443
```

---

## 3. 全体構成

```text
Internet
  |
  | TCP 25565 / TCP 80 / TCP 443
  v
+-----------------------------+
| alice-01                    |
|-----------------------------|
| Load Balancer               |
| WireGuard endpoint          |
| BGP router                  |
| Firewall                    |
| Kubernetesなし              |
+--------------+--------------+
               |
               | WireGuard
               | BGP over WireGuard
               |
+--------------v--------------+
| inuyama                     |
|-----------------------------|
| Kubernetes Cluster          |
| API VIP: 192.168.1.100      |
| k8s1: control-plane / etcd  |
| k8s2: control-plane / etcd  |
| k8s4: control-plane / etcd  |
| worker nodes                |
| Ingress / Service backend   |
+-----------------------------+
```

---

## 4. 役割分担

## 4.1 inuyama

`inuyama` は Kubernetes 本体を持つ。

| Component         | Role                 |
| ----------------- | -------------------- |
| `k8s1`            | control-plane / etcd |
| `k8s2`            | control-plane / etcd |
| `k8s4`            | control-plane / etcd |
| workers           | application workload |
| kube-vip          | Kubernetes API VIP   |
| Ingress / Service | aliceからの転送先    |

## 4.2 alice

`alice` は1ホスト構成とする。

| Component  | Role           |
| ---------- | -------------- |
| `alice-01` | public gateway |
| WireGuard  | 拠点間VPN      |
| FRR / BGP  | 内部経路交換   |
| HAProxy    | L4ロードバランサー |
| Firewall   | 外部公開制御   |

`alice-01` は単一障害点である。

| 障害                 | 影響                       |
| -------------------- | -------------------------- |
| `alice-01`停止       | alice経由の外部公開停止    |
| WireGuard停止        | alice → inuyama 接続停止   |
| HAProxy停止          | 25565/80/443 の転送停止    |
| BGP停止              | 内部経路交換停止           |
| inuyama側Kubernetes | alice障害時も継続          |

---

## 5. ネットワーク設計

## 5.1 既存LAN

| 拠点      | Prefix              |
| --------- | ------------------- |
| inuyama   | `192.168.1.0/24`    |
| alice     | 未確定。alice側実LANに合わせる |

## 5.2 WireGuard Transit

WireGuard用のTransitネットワークは既存LANと重複しないレンジを使う。

| Endpoint    | Address           |
| ----------- | ----------------- |
| inuyama wg0 | `172.31.255.1/30` |
| alice wg0   | `172.31.255.2/30` |

```text
WireGuard listen port:
  UDP 51820
```

## 5.3 BGP ASN

| 拠点      |     ASN |
| --------- | ------: |
| inuyama   | `65010` |
| alice     | `65020` |

BGPはWireGuard内部でのみ利用する。

```text
BGP peer:
  172.31.255.1 <-> 172.31.255.2
```

---

## 6. WireGuard設計

## 6.1 起動方式

WireGuardは Kubernetes / static Pod ではなく `systemd` で管理する。

```text
wg-quick@wg0.service
```

理由：

* aliceはKubernetesノードではない
* OS起動時にVPNを先に確立できる
* Kubernetes障害時もVPN経路を独立維持できる
* BGP/HAProxyの起動前提として扱える

## 6.2 inuyama側設定例

```ini
[Interface]
Address = 172.31.255.1/30
ListenPort = 51820
PrivateKey = <inuyama-private-key>
MTU = 1420

[Peer]
PublicKey = <alice-public-key>
AllowedIPs = 172.31.255.2/32, <alice-prefix>
Endpoint = <alice-public-ip>:51820
PersistentKeepalive = 25
```

## 6.3 alice側設定例

```ini
[Interface]
Address = 172.31.255.2/30
ListenPort = 51820
PrivateKey = <alice-private-key>
MTU = 1420

[Peer]
PublicKey = <inuyama-public-key>
AllowedIPs = 172.31.255.1/32, 192.168.1.0/24
Endpoint = <inuyama-public-ip>:51820
PersistentKeepalive = 25
```

## 6.4 systemd

```bash
sudo systemctl enable --now wg-quick@wg0
```

aliceでは、FRR/HAProxyをWireGuard後に起動させる。

```ini
[Unit]
After=network-online.target wg-quick@wg0.service
Wants=network-online.target wg-quick@wg0.service
```

---

## 7. BGP設計

## 7.1 方針

BGPは内部向けのみ。

```text
外部IF:
  tcp/179 deny

wg0:
  tcp/179 allow between 172.31.255.1 and 172.31.255.2
```

## 7.2 広告経路

### inuyama → alice

最低限：

```text
192.168.1.0/24
```

必要に応じて、Ingress / Service公開用VIPを `/32` で広告する。

```text
192.168.1.240/32
192.168.1.241/32
```

### alice → inuyama

必要に応じてalice側の公開VIPまたは内部prefixを広告する。

```text
<alice-vip>/32
<alice-internal-prefix>
```

## 7.3 Prefix Filter

aliceがinuyamaから受ける経路：

```text
permit 192.168.1.0/24
permit 192.168.1.240/32
permit 192.168.1.241/32
deny any
```

inuyamaがaliceから受ける経路：

```text
permit <alice-vip>/32
permit <alice-internal-prefix>
deny any
```

以下はBGP広告しない。

```text
Pod CIDR
Service CIDR
Cluster internal IP
```

---

## 8. Load Balancer設計

## 8.1 方針

`alice-01` のHAProxyで `25565/80/443` を受け、WireGuard経由で `inuyama` のバックエンドへ転送する。

```text
Client
  -> alice public_ip:25565/80/443
  -> alice HAProxy
  -> WireGuard
  -> inuyama backend
  -> Kubernetes Service / Pod
```

## 8.2 転送先

| alice frontend | inuyama backend       |
| -------------- | --------------------- |
| `:80`          | `192.168.1.240:80`    |
| `:443`         | `192.168.1.240:443`   |
| `:25565`       | `192.168.1.241:25565` |

犬山LAN `192.168.1.0/24` の kube-vip LoadBalancer 用VIPとして以下を予約する。

| Address             | 用途                    |
| ------------------- | ----------------------- |
| `192.168.1.240`     | Ingress VIP             |
| `192.168.1.241`     | Minecraft Backend VIP   |
| `192.168.1.242-249` | 将来用VIP予約           |

実環境では既存LoadBalancerがMetalLB `main-pool` で運用されているため、alice用VIPは `main-pool` に `192.168.1.240-192.168.1.249` を追加し、既存のIngress/Minecraft Serviceとは別のalice専用LoadBalancer Serviceとして割り当てる。

---

## 9. HAProxy設定例

```haproxy
global
    log /dev/log local0
    daemon
    maxconn 4096

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client  1h
    timeout server  1h

frontend http_in
    bind *:80
    mode tcp
    default_backend http_backend

frontend https_in
    bind *:443
    mode tcp
    default_backend https_backend

frontend minecraft_in
    bind *:25565
    mode tcp
    default_backend minecraft_backend

backend http_backend
    mode tcp
    option tcp-check
    server web1 192.168.1.240:80 check

backend https_backend
    mode tcp
    option tcp-check
    server web1 192.168.1.240:443 check

backend minecraft_backend
    mode tcp
    option tcp-check
    server mc1 192.168.1.241:25565 check
```

Minecraftは長時間接続を考慮し、`timeout client/server` を短くしすぎない。

---

## 10. Firewall設計

## 10.1 alice external inbound

|    Port | Protocol | Source         | 用途        |
| ------: | -------- | -------------- | ----------- |
| `25565` | TCP      | Internet       | Minecraft   |
|    `80` | TCP      | Internet       | HTTP        |
|   `443` | TCP      | Internet       | HTTPS       |
| `51820` | UDP      | inuyama peer推奨 | WireGuard |

明示的に閉じる。

|        Port | Protocol | 理由                           |
| ----------: | -------- | ------------------------------ |
|       `179` | TCP      | BGPはWireGuard内部のみ          |
|      `6443` | TCP      | Kubernetes APIをalice外部へ公開しない |
| `2379-2380` | TCP      | etcdを外部公開しない            |
|     `10250` | TCP      | kubeletを外部公開しない         |

## 10.2 alice wg0

| From | To | Port | 用途 |
| --- | --- | ---: | --- |
| `172.31.255.1` | `172.31.255.2` | `179/tcp` | BGP |
| `alice-01` | `192.168.1.240` | `80/tcp` | HTTP転送 |
| `alice-01` | `192.168.1.240` | `443/tcp` | HTTPS転送 |
| `alice-01` | `192.168.1.241` | `25565/tcp` | Minecraft転送 |

## 10.3 inuyama

inuyama側では、aliceから必要なバックエンドだけを許可する。

| From | To | Port |
| --- | --- | ---: |
| `alice wg0` | `192.168.1.240` | `80/tcp` |
| `alice wg0` | `192.168.1.240` | `443/tcp` |
| `alice wg0` | `192.168.1.241` | `25565/tcp` |
| `alice wg0` | BGP peer | `179/tcp` |

Kubernetes API `6443/tcp` は、aliceから運用上必要な場合のみ許可する。

---

## 11. 監視マップ設計

`alice` と `inuyama` 間の host / WireGuard / BGP / HAProxy / backend VIP の可視化は、[WireGuard Network Map 設計書](wireguard-network-map-design.md) を正とする。

最小構成では Grafana Canvas に以下を表示する。

| 対象 | 表示 |
| --- | --- |
| `alice-01` | host up/down, HAProxy, FRR, `wg0` RX/TX |
| `k8s4` | host up/down, BIRD, `wg0` RX/TX |
| WireGuard tunnel | RTT, handshake age, `probe_success` |
| backend VIP | `192.168.1.240:80/443`, `192.168.1.241:25565` のTCP probe |
