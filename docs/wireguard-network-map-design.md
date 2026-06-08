# WireGuard Network Map 設計書

**対象リポジトリ:** `kigawa-net/infra`
**対象:** `inuyama` / `alice` 間の host + WireGuard 可視化
**推奨方式:** 初期実装は Grafana Canvas。自動トポロジ化が必要になったら Node Graph を追加する。

---

## 1. 目的

`host + WireGuard` の状態を単なる時系列グラフではなく、拠点、ホスト、WireGuard tunnel、LB/BGP の関係が分かるネットワークマップとして表示する。

| 方式 | 向いている用途 |
| --- | --- |
| Grafana Canvas / Node Graph | Prometheus中心で軽量にマップ化する |
| NetBox + Grafana / Weathermap | 拠点、機器、回線情報も台帳管理する |

初期段階では **Grafana Canvas** を採用する。理由は、`inuyama` / `alice` / host / `wg0` / LB / BGP の関係を固定配置でき、運用者が見たい構図にしやすいため。

---

## 2. 対象トポロジ

### 2.1 現状

現状のWireGuard endpointは `k8s4` と `alice-01` の1本を正とする。

```text
Internet / Client
   |
   | tcp/80, tcp/443, tcp/25565
   v
alice-01
  - HAProxy
  - FRR / BGP AS65020
  - WireGuard wg0: 172.31.255.2/30
   |
   | WireGuard tunnel
   | BGP over WireGuard
   v
k8s4
  - WireGuard wg0: 172.31.255.1/30
  - BIRD / BGP AS65010
  - Kubernetes control-plane
   |
   v
inuyama Kubernetes / MetalLB / Ingress / Minecraft
```

### 2.2 将来拡張

`k8s1`, `k8s2`, `k8s4` の各control-planeにWireGuard endpointを増やす場合は、star型で描く。

```text
          k8s1
           |
        wg tunnel
           |
k8s2 -- alice-01 -- Internet / Client
           |
        wg tunnel
           |
          k8s4
```

---

## 3. マップ分割

一枚に詰め込まず、運用では次の3枚に分ける。

| Dashboard | 表示内容 |
| --- | --- |
| Physical map | site、host、LAN、router/switchの物理配置 |
| Overlay map | WireGuard tunnel、BGP peer、handshake、RTT |
| Service map | Client -> alice HAProxy -> WireGuard -> inuyama Service |

最小実装では **Overlay map** と **Service map** を1枚のCanvasにまとめてよい。

---

## 4. 表示ノード

| Node | Site | Role |
| --- | --- | --- |
| `alice-01` | alice | public gateway, HAProxy, WireGuard endpoint, FRR/BGP |
| `k8s1` | inuyama | Kubernetes control-plane / etcd |
| `k8s2` | inuyama | Kubernetes control-plane / etcd |
| `k8s4` | inuyama | Kubernetes control-plane / etcd, WireGuard endpoint, BIRD/BGP |
| `inuyama-ingress-vip` | inuyama | `192.168.1.240`, HTTP/HTTPS backend VIP |
| `minecraft-backend-vip` | inuyama | `192.168.1.241`, Minecraft backend VIP |

ノード状態として次を表示する。

| 表示 | Prometheus metric |
| --- | --- |
| host up/down | `up{job="node"}` |
| WireGuard service | `node_systemd_unit_state{name="wg-quick@wg0.service", state="active"}` |
| CPU | `node_cpu_seconds_total` |
| memory | `node_memory_*` |
| wg0 RX/TX | `node_network_receive_bytes_total{device="wg0"}`, `node_network_transmit_bytes_total{device="wg0"}` |
| HAProxy active | `node_systemd_unit_state{name="haproxy.service", state="active"}` |
| BGP daemon active | `node_systemd_unit_state{name="frr.service", state="active"}` or BIRD exporter equivalent |

---

## 5. 表示エッジ

現状の最小エッジは次の1本。

```text
k8s4 wg0 <-> alice-01 wg0
```

Service mapでは次の流れを表示する。

```text
Internet / Client
  -> alice-01:80/443/25565
  -> alice HAProxy
  -> wg0 tunnel
  -> 192.168.1.240:80/443
  -> 192.168.1.241:25565
```

エッジ状態として次を表示する。

| 表示 | Prometheus metric / query |
| --- | --- |
| RX bitrate | `rate(node_network_receive_bytes_total{device="wg0"}[5m]) * 8` |
| TX bitrate | `rate(node_network_transmit_bytes_total{device="wg0"}[5m]) * 8` |
| alice -> k8s4 bitrate | `sum(rate(node_network_receive_bytes_total{instance=~"(k8s4|192.168.1.120:9100)", device="wg0"}[5m])) * 8` |
| k8s4 -> alice bitrate | `sum(rate(node_network_transmit_bytes_total{instance=~"(k8s4|192.168.1.120:9100)", device="wg0"}[5m])) * 8` |
| alice -> k8s4 traffic volume | `sum(increase(node_network_receive_bytes_total{instance=~"(k8s4|192.168.1.120:9100)", device="wg0"}[5m]))` |
| k8s4 -> alice traffic volume | `sum(increase(node_network_transmit_bytes_total{instance=~"(k8s4|192.168.1.120:9100)", device="wg0"}[5m]))` |
| handshake age | `time() - wireguard_latest_handshake_seconds` |
| tunnel up/down | `probe_success{job="blackbox-wireguard"}` |
| RTT | `probe_duration_seconds{job="blackbox-wireguard"}` |

---

## 6. Exporter構成

各ホストに配置する。

```text
node_exporter
wireguard_exporter
```

監視側に配置する。

```text
Prometheus
blackbox_exporter
Grafana
```

WireGuard exporterが未導入の場合でも、初期段階では `node_exporter` の `wg0` interface traffic と `blackbox_exporter` の疎通確認でCanvas化できる。

---

## 7. Prometheus scrape例

実環境の最小例。

```yaml
scrape_configs:
  - job_name: node
    static_configs:
      - targets:
          - 192.168.1.103:9100   # k8s1
          - 192.168.1.20:9100    # k8s2
          - 192.168.1.120:9100   # k8s4
          - 172.31.255.2:9100    # alice-01 over WireGuard

  - job_name: wireguard
    static_configs:
      - targets:
          - 192.168.1.120:9586   # k8s4
          - 172.31.255.2:9586    # alice-01

  - job_name: blackbox-wireguard
    metrics_path: /probe
    params:
      module: [icmp]
    static_configs:
      - targets:
          - 172.31.255.1         # k8s4 wg0
          - 172.31.255.2         # alice wg0
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-exporter:9115
```

`alice-01` のnode_exporterをpublic側で開けず、WireGuard内部またはPrometheus配置拠点からのみscrapeする。

---

## 8. PromQL

### Host up

```promql
up{job="node"}
```

### WireGuard service active

```promql
node_systemd_unit_state{name="wg-quick@wg0.service", state="active"}
```

### wg0 receive bitrate

```promql
rate(node_network_receive_bytes_total{device="wg0"}[5m]) * 8
```

### wg0 transmit bitrate

```promql
rate(node_network_transmit_bytes_total{device="wg0"}[5m]) * 8
```

### WireGuard handshake age

```promql
time() - wireguard_latest_handshake_seconds
```

### Tunnel reachability

```promql
probe_success{job="blackbox-wireguard"}
```

### Tunnel RTT

```promql
probe_duration_seconds{job="blackbox-wireguard"}
```

---

## 9. Grafana Canvas設計

Canvasでは固定配置で表示する。

```text
[Internet]
    |
    | 80/443/25565
    v
[alice-01]
  HAProxy: active
  BGP: established
  wg0: 172.31.255.2
    |
    | alice -> k8s4 bps + last 5m bytes
    | k8s4 -> alice bps + last 5m bytes
    | RTT ms / handshake age / OK
    v
[k8s4]
  wg0: 172.31.255.1
  BIRD: established
    |
    +--> [Ingress VIP 192.168.1.240]
    +--> [Minecraft VIP 192.168.1.241]
```

色分けは次を標準にする。

| 状態 | 表示 |
| --- | --- |
| 正常 | green |
| handshake stale | yellow |
| tunnel down | red |
| unknown / no data | gray |

推奨しきい値。

| 項目 | green | yellow | red |
| --- | ---: | ---: | ---: |
| handshake age | `< 120s` | `120s - 300s` | `> 300s` |
| probe_success | `1` | - | `0` |
| RTT | `< 50ms` | `50ms - 200ms` | `> 200ms` |

---

## 10. Grafana Node Graph設計

Node Graphを使う場合は、Prometheusの値をそのままではなく `nodes` / `edges` 形式へ加工する。

### nodes

```text
id,title,subtitle,mainstat
alice-01,alice-01,alice,UP
k8s1,k8s1,inuyama,UP
k8s2,k8s2,inuyama,UP
k8s4,k8s4,inuyama,UP
```

### edges

```text
id,source,target,mainstat,secondarystat
wg-k8s4-alice,k8s4,alice-01,42 Mbps,8 ms
```

この形式は Infinity datasource や JSON API datasource で返す。将来的に複数WireGuard endpointへ拡張する場合は、edgeを増やす。

```text
wg-k8s1-alice,k8s1,alice-01,15 Mbps,9 ms
wg-k8s2-alice,k8s2,alice-01,18 Mbps,8 ms
wg-k8s4-alice,k8s4,alice-01,42 Mbps,7 ms
```

---

## 11. Alert設計

最小アラートは次の通り。

| Alert | 条件 |
| --- | --- |
| `WireGuardTunnelDown` | `probe_success{job="blackbox-wireguard"} == 0` が5分継続 |
| `WireGuardHandshakeStale` | `time() - wireguard_latest_handshake_seconds > 300` |
| `AliceHAProxyDown` | `node_systemd_unit_state{name="haproxy.service", state="active"} != 1` |
| `AliceBGPDown` | FRR/BGP exporter または `vtysh` exporterでpeer down |
| `InuyamaBackendUnreachable` | blackbox TCP probeで `192.168.1.240:80/443` または `192.168.1.241:25565` が失敗 |

---

## 12. 最小実装順

1. `node_exporter` で `alice-01`, `k8s1`, `k8s2`, `k8s4` をscrapeする。
2. `blackbox_exporter` で `172.31.255.1`, `172.31.255.2`, `192.168.1.240:80`, `192.168.1.240:443`, `192.168.1.241:25565` をprobeする。
3. `wireguard_exporter` を `alice-01` と `k8s4` に入れてhandshake ageを取得する。
4. Grafana Canvasで固定配置のOverlay/Service mapを作る。
5. 必要になったら Node Graph用JSON APIを追加し、自動トポロジ化する。

---

## 13. 結論

`host + WireGuard` のネットワークマップは次の構成で始める。

```text
Prometheus
  |- node_exporter
  |- wireguard_exporter
  `- blackbox_exporter
        |
        v
Grafana
  |- Canvas: 固定配置のネットワークマップ
  `- Node Graph: nodes/edges形式の自動トポロジ
```

初期実装は Grafana Canvas を正とする。
