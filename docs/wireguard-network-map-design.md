# WireGuard Network Map 設計書

**対象リポジトリ:** `kigawa-net/infra`
**対象:** `inuyama` / `alice` 間の host + WireGuard 可視化
**推奨方式:** Shumoku topology YAML を正とし、Prometheus の値をリンク使用率・状態表示へ紐付ける。

---

## 1. 目的

`host + WireGuard` の状態を単なる時系列グラフではなく、拠点、ホスト、WireGuard tunnel、LB/BGP、backend VIP の関係が分かるネットワークマップとして表示する。

| 方式 | 位置づけ |
| --- | --- |
| Shumoku | ネットワークトポロジーマップの正。YAMLをGit管理し、必要に応じてPrometheusを紐付ける |
| Grafana Canvas / Node Graph | 既存Grafana監視の補助表示。時系列パネルやalert確認に使う |
| NetBox + Shumoku | 機器、回線、IPAMを台帳管理したくなった場合の将来拡張 |

Shumokuを採用する理由は、ネットワーク図を `topology.yaml` としてレビュー可能なIaCにでき、Grafanaのパネル編集に依存せず host / port / link の関係を明示できるため。

---

## 2. 対象トポロジ

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
inuyama Kubernetes / kube-vip LoadBalancer
  - Ingress VIP: 10.0.1.240
  - Minecraft backend VIP: 10.0.1.241
```

将来 `k8s1`, `k8s2`, `k8s4` の各control-planeにWireGuard endpointを増やす場合は、`alice-01` を中心としたstar型にする。

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

## 3. Shumoku定義

トポロジー定義は次を正とする。

```text
platform/monitoring/wireguard-map/shumoku-topology.yaml
```

ShumokuのYAMLは `nodes` と `links` で構成する。現状はOverlay mapとService mapを1枚にまとめる。

| Node | Site | Role |
| --- | --- | --- |
| `internet-client` | external | public client |
| `alice-01` | alice | public gateway, HAProxy, WireGuard endpoint, FRR/BGP |
| `k8s4` | inuyama | Kubernetes control-plane / etcd, WireGuard endpoint, BIRD/BGP |
| `inuyama-ingress-vip` | inuyama | `10.0.1.240`, HTTP/HTTPS backend VIP |
| `minecraft-backend-vip` | inuyama | `10.0.1.241`, Minecraft backend VIP |

| Link | 表示 |
| --- | --- |
| `internet-to-alice` | Internetからalice公開ポートへの入口 |
| `alice-k8s4-wireguard` | WireGuard tunnel / BGP peer |
| `k8s4-to-ingress` | HTTP/HTTPS backend path |
| `k8s4-to-minecraft` | Minecraft backend path |

生成物のSVG/HTML/PNGはコミットしない。必要なときにShumoku CLIまたはShumoku serverで生成する。

```bash
npx shumoku render platform/monitoring/wireguard-map/shumoku-topology.yaml -o /tmp/wireguard-map.svg
npx shumoku render platform/monitoring/wireguard-map/shumoku-topology.yaml -f html -o /tmp/wireguard-map.html
```

---

## 4. Prometheus連携

Shumoku serverでライブ表示する場合は、TopologyのSettingsからPrometheusをMetrics Sourceとして追加し、Node MappingでShumoku nodeと監視対象hostを紐付ける。

| Shumoku node | Prometheus対象 |
| --- | --- |
| `alice-01` | `172.31.255.2:9100` or alice scrape label |
| `k8s4` | `10.0.1.120:9100` or `k8s4` |
| `inuyama-ingress-vip` | blackbox target `10.0.1.240:80`, `10.0.1.240:443` |
| `minecraft-backend-vip` | blackbox target `10.0.1.241:25565` |

現状は `k8s4` の `wg0` node_exporter metricsを使い、WireGuard linkの方向別trafficを表示する。

| Direction | PromQL |
| --- | --- |
| `alice -> k8s4` bitrate | `sum(rate(node_network_receive_bytes_total{instance=~"(k8s4|10.0.1.120:9100)", device="wg0"}[5m])) * 8` |
| `k8s4 -> alice` bitrate | `sum(rate(node_network_transmit_bytes_total{instance=~"(k8s4|10.0.1.120:9100)", device="wg0"}[5m])) * 8` |
| `alice -> k8s4` traffic volume | `sum(increase(node_network_receive_bytes_total{instance=~"(k8s4|10.0.1.120:9100)", device="wg0"}[5m]))` |
| `k8s4 -> alice` traffic volume | `sum(increase(node_network_transmit_bytes_total{instance=~"(k8s4|10.0.1.120:9100)", device="wg0"}[5m]))` |
| handshake age | `time() - wireguard_latest_handshake_seconds` |
| tunnel up/down | `probe_success{job="blackbox-wireguard"}` |
| RTT | `probe_duration_seconds{job="blackbox-wireguard"}` |

`alice-01` のnode_exporterをscrapeできるようになったら、alice側の `wg0` metricsもShumokuのリンク表示に追加する。

---

## 5. Exporter構成

各ホストに配置する。

```text
node_exporter
wireguard_exporter
```

監視側に配置する。

```text
Prometheus
blackbox_exporter
Shumoku
Grafana
```

WireGuard exporterが未導入の場合でも、初期段階では `node_exporter` の `wg0` interface traffic と `blackbox_exporter` の疎通確認でShumokuのリンク状態を表現する。

`alice-01` のnode_exporterをpublic側で開けず、WireGuard内部またはPrometheus配置拠点からのみscrapeする。

---

## 6. Prometheus scrape例

実環境の最小例。

```yaml
scrape_configs:
  - job_name: node
    static_configs:
      - targets:
          - 10.0.1.103:9100   # k8s1
          - 10.0.1.20:9100    # k8s2
          - 10.0.1.120:9100   # k8s4
          - 172.31.255.2:9100    # alice-01 over WireGuard

  - job_name: wireguard
    static_configs:
      - targets:
          - 10.0.1.120:9586   # k8s4
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

---

## 7. 表示状態としきい値

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

## 8. Alert設計

最小アラートは次の通り。

| Alert | 条件 |
| --- | --- |
| `WireGuardTunnelDown` | `probe_success{job="blackbox-wireguard"} == 0` が5分継続 |
| `WireGuardHandshakeStale` | `time() - wireguard_latest_handshake_seconds > 300` |
| `AliceHAProxyDown` | `node_systemd_unit_state{name="haproxy.service", state="active"} != 1` |
| `AliceBGPDown` | FRR/BGP exporter または `vtysh` exporterでpeer down |
| `InuyamaBackendUnreachable` | blackbox TCP probeで `10.0.1.240:80/443` または `10.0.1.241:25565` が失敗 |

---

## 9. 最小実装順

1. `platform/monitoring/wireguard-map/shumoku-topology.yaml` をShumokuへ登録する。
2. `node_exporter` で `alice-01`, `k8s1`, `k8s2`, `k8s4` をscrapeする。
3. `blackbox_exporter` で `172.31.255.1`, `172.31.255.2`, `10.0.1.240:80`, `10.0.1.240:443`, `10.0.1.241:25565` をprobeする。
4. `wireguard_exporter` を `alice-01` と `k8s4` に入れてhandshake ageを取得する。
5. Shumoku serverのPrometheus Metrics SourceとNode Mappingでtraffic / RTT / handshakeをリンクへ紐付ける。

---

## 10. 結論

`host + WireGuard` のネットワークマップは次の構成で始める。

```text
Prometheus
  |- node_exporter
  |- wireguard_exporter
  `- blackbox_exporter
        |
        v
Shumoku
  |- topology.yaml: host / WireGuard / backend VIP の構造
  `- Prometheus Metrics Source: traffic / RTT / status

Grafana
  `- 既存監視ダッシュボードと時系列確認
```

初期実装は Shumoku topology YAML を正とする。
