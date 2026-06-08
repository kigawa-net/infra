# WireGuard Network Map Monitoring Assets

`inuyama` / `alice` 間の WireGuard gateway を Shumoku でネットワークトポロジーマップ表示するための雛形です。

関連設計書:

- `docs/alice-gateway-design.md`
- `docs/wireguard-network-map-design.md`

## Files

| File | 用途 |
| --- | --- |
| `shumoku-topology.yaml` | Shumoku topology map定義 |
| `prometheus-scrape.yaml` | node / wireguard / blackbox scrape設定例 |
| `blackbox-modules.yaml` | ICMP/TCP probe module設定例 |
| `prometheus-rules.yaml` | tunnel/backend/host/service alert rule例 |

## 現状トポロジ

```text
Internet / Client
  -> alice-01:80/443/25565
  -> HAProxy
  -> WireGuard wg0
  -> k8s4 wg0
  -> inuyama backend VIPs
```

| Endpoint | Address |
| --- | --- |
| `k8s4 wg0` | `172.31.255.1` |
| `alice wg0` | `172.31.255.2` |
| Ingress VIP | `192.168.1.240` |
| Minecraft VIP | `192.168.1.241` |

## 使い方

1. `prometheus-scrape.yaml` のtargetsを既存Prometheus設定に取り込む。
2. `blackbox-modules.yaml` のmoduleを既存blackbox_exporter設定に取り込む。
3. `prometheus-rules.yaml` をPrometheus ruleとして読み込む。
4. `shumoku-topology.yaml` をShumokuへ登録する。
5. Shumoku serverのMetrics SourceにPrometheusを追加し、Node Mappingで `alice-01`, `k8s4`, backend VIPを監視対象へ紐付ける。

CLIで静的図を生成する場合は次を使う。生成したSVG/HTML/PNGはコミットしない。

```bash
npx shumoku render platform/monitoring/wireguard-map/shumoku-topology.yaml -o /tmp/wireguard-map.svg
npx shumoku render platform/monitoring/wireguard-map/shumoku-topology.yaml -f html -o /tmp/wireguard-map.html
```

Shumoku上のWireGuard linkには、Prometheus連携で方向別のbitrateと直近5分の転送量を表示する。

| Direction | Bitrate | Traffic volume |
| --- | --- | --- |
| `alice -> k8s4` | `sum(rate(node_network_receive_bytes_total{instance=~"(k8s4|192.168.1.120:9100)", device="wg0"}[5m])) * 8` | `sum(increase(node_network_receive_bytes_total{instance=~"(k8s4|192.168.1.120:9100)", device="wg0"}[5m]))` |
| `k8s4 -> alice` | `sum(rate(node_network_transmit_bytes_total{instance=~"(k8s4|192.168.1.120:9100)", device="wg0"}[5m])) * 8` | `sum(increase(node_network_transmit_bytes_total{instance=~"(k8s4|192.168.1.120:9100)", device="wg0"}[5m]))` |

色分けはトラフィック量の強さを示す。障害状態はprobe/handshake/service alert ruleを正とする。

Grafana dashboard本体は `kigawa01/k8s-system` の `prometheus/wireguard-network-map-dashboard.yml` をArgoCDで同期する。これは既存監視の補助表示として残す。

`alice-01` の exporter はpublic internetへ公開せず、WireGuard内部または監視拠点からだけscrapeしてください。
