# WireGuard Network Map Monitoring Assets

`inuyama` / `alice` 間の WireGuard gateway を Grafana でネットワークマップ表示するための雛形です。

関連設計書:

- `docs/alice-gateway-design.md`
- `docs/wireguard-network-map-design.md`

## Files

| File | 用途 |
| --- | --- |
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
4. Grafana dashboard本体は `kigawa01/k8s-system` の `prometheus/wireguard-network-map-dashboard.yml` をArgoCDで同期する。

Grafana dashboard の先頭パネルは `type: canvas` の固定配置ネットワークマップです。WireGuard tunnel 上には query-backed の `metric-value` を置き、方向別に現在のbitrateと直近5分の転送量を表示します。下段のStat/Time seriesパネルもPrometheus query-backedです。

Canvas上のトラフィック表示:

| Direction | Bitrate | Traffic volume |
| --- | --- | --- |
| `alice -> k8s4` | `sum(rate(node_network_receive_bytes_total{instance=~"(k8s4|192.168.1.120:9100)", device="wg0"}[5m])) * 8` | `sum(increase(node_network_receive_bytes_total{instance=~"(k8s4|192.168.1.120:9100)", device="wg0"}[5m]))` |
| `k8s4 -> alice` | `sum(rate(node_network_transmit_bytes_total{instance=~"(k8s4|192.168.1.120:9100)", device="wg0"}[5m])) * 8` | `sum(increase(node_network_transmit_bytes_total{instance=~"(k8s4|192.168.1.120:9100)", device="wg0"}[5m]))` |

色分けはトラフィック量の強さを示します。障害状態は下段のprobe/handshake/serviceパネルとalert ruleを正としてください。

`alice-01` の exporter はpublic internetへ公開せず、WireGuard内部または監視拠点からだけscrapeしてください。
