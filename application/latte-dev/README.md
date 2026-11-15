# latte-dev の prod ingress

関連参照（依頼指定）: kigawa-net/infra#506。
ただし GitHub 上の #506 は `fix: litellm.kigawa.netのCloudflare 525エラーを修正` という
マージ済み PR で、依頼にある `node port 80 is not listening` と件名が異なる。
該当障害の正しい Issue URL は未確認。

`prod/` は **prod クラスタ専用**。外部経路は
Cloudflare → ionos → `10.0.0.240:443` (HAProxy、TLS 終端) →
`latte-dev-svc:8765` → `192.168.1.242:8765` (平文 WebSocket RPC)。
Host は `latte-dev.kigawa.net`、パスは書き換えず `/` 以下を転送する。
外部クライアントは `wss://latte-dev.kigawa.net/` の 443 を使用する。
8766 の debug HTTP は公開しない。

既存の `application/latte-ai/` と、192.168.1.242 側の nginx Ingress・Service は
この同期対象に含めない。今回の構成は 192.168.1.242 の ingress-nginx の 80 番や
暫定 `externalIPs` に依存せず、AI Server の 8765 に直接接続する。
暫定 `externalIPs` の恒久化はこの変更の対象外。

## Service と WebSocket

固定 IP を DNS 解決せずに扱うため、selector なし ClusterIP Service と手動管理の
EndpointSlice を使用する。Service のポート名 `websocket` と EndpointSlice の
ポート名を一致させる。`externalName: 192.168.1.242` は IP ではなく DNS 名として
扱われるので使用しない。

HAProxy は HTTP/1.1 Upgrade による WebSocket を転送する。Ingress には既存例に
合わせて `haproxy.org/timeout-server: "120s"` を指定する。
Upgrade 後の無通信タイムアウトは既存の HAProxy ConfigMap の `timeout-tunnel` を
継承する（コントローラ既定値は 1h）。`timeout-tunnel` は ConfigMap 専用なので
Ingress annotation には指定しない。Cloudflare を含む長時間接続にはクライアントの
ping/pong と再接続を使用する。

仕様:

- [Kubernetes: selector なし Service / ExternalName](https://kubernetes.io/docs/concepts/services-networking/service/)
- [HAProxy: timeouts](https://github.com/haproxytech/kubernetes-ingress/blob/master/documentation/annotations.md#timeouts)

## 反映の前提と未完了の作業

この PR は manifest の追加のみで、クラスタには apply しない。
infra の `application/` は既存の本番 ArgoCD の管理対象ではないため、**マージだけでは
反映されない**。`argocd/latte-dev-app.yaml` は infra の `main` の `prod/` だけを
同期する Application 定義で、既存の kigawa-net-k8s の Application パターンに従う。
kigawa の許可後、prod を管理する kigawa-net-k8s の `apps/` にこの定義を登録する
別 PR が必要。この PR では登録・マージ・同期を実行しない。
Namespace は Application の `CreateNamespace=true` で作成する。

公開 DNS に明示的な DNS-only の `latte-dev.kigawa.net → 192.168.1.242` が残ると、
ワイルドカードの Cloudflare プロキシレコードより優先され、外部から到達できない。
別作業でそのレコードを除去して既存のプロキシ有効ワイルドカードを利用するか、
既存の公開 origin を指すプロキシ有効レコードに切り替える必要がある。
この PR は DNS を変更しない。

反映前に prod HAProxy が EndpointSlice を参照でき、Pod から
`192.168.1.242:8765` に TCP 接続できることを確認する。バックエンドが外部 Host / Origin
を受け入れること、既存のデフォルト TLS 証明書でこのホストを処理できることも確認する。
共有経路・証明書・ファイアウォールの設定変更はこの PR に含まない。

## 受け入れ条件（反映後に確認）

1. prod で `latte-dev-ing` が HAProxy に取り込まれ、backend が
   `192.168.1.242:8765` になっている。
2. `10.0.0.240:443` に Host / SNI を指定した接続で WebSocket の
   `101 Switching Protocols` が返り、RPC の要求・応答と ping/pong が成功する。
3. Cloudflare の IP を指定した接続でも同じ RPC と ping/pong が成功する。
4. 公開 DNS が Cloudflare の IP を返し、通常の外部クライアントでも
   `wss://latte-dev.kigawa.net/` で接続できる。

Upgrade の確認例（`--max-time` による終了コード 28 と Upgrade 成否は区別する）:

```bash
curl --http1.1 --include --no-buffer --max-time 10 \
  --resolve latte-dev.kigawa.net:443:10.0.0.240 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  https://latte-dev.kigawa.net/
```

Cloudflare 経由の確認では `--resolve` の IP を既存のプロキシ有効ホストの公開 DNS から
取得した Cloudflare IP に置き換える。DNS-only の latte-dev 自身の応答は使わない。
`101` だけでは RPC の成功を判定できないため、Latte クライアントでも実際の RPC を
実行する。現在は未反映のため、これらの受け入れ条件は未検証。

ロールバックは Application 登録とこの Ingress/Service/EndpointSlice の変更を
Git 上で戻す。既存サイトの経路や 192.168.1.242 側を変更する必要はない。
