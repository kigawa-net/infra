# ingress への経路と、ホストの追加(Host ベースの振り分け)

2026-11-13 の障害(#500、#503、#513)の振り返りを含む。**ネットワークの経路を変える前に読むこと。**

## 経路(外部からの通信)

```
ブラウザ → Cloudflare(SSL: full、プロキシ有効) → ionos 74.208.55.86:443
        → haproxy(ionos、mode tcp = TLS を素通し) → 10.0.0.240:443(inuyama-ingress、MetalLB の VIP)
        → HAProxy Ingress(Pod haproxy-kubernetes-ingress。TLS を終端し、Host で Ingress を選ぶ) → Service → Pod
```

- ionos → 10.0.0.240 は、BGP(FRR)が決めた経路で届く(GRE・WireGuard 経由)。EasyTier のオーバーレイは、BGP のセッションを運ぶ。
- `inuyama-ingress`(10.0.0.240)と `haproxy-kubernetes-ingress`(10.0.0.58)は、**同じ HAProxy Ingress の Pod**(同じ selector)を指す。
- 内部からの通信は、内部 DNS(Knot、`*.kigawa.net` → `10.0.0.240`)が、直接 10.0.0.240 に向ける(Cloudflare を通らない)。

## Host ベースの振り分けは、すでにある

振り分けは、**HAProxy Ingress が、`Ingress` ごとに行う**。本番に **Istio はない**(CRD も Gateway もない。`application/latte-ai/*` の Istio は、本番の ArgoCD の管理外)。

ホストを足す手順:
1. `kigawa-net-k8s` に `Ingress`(`ingressClassName: haproxy`、`host: <名前>.kigawa.net`)を足す
2. DNS は、足さない(ワイルドカード `*` → `web-base`、プロキシ有効が、すでにある)
3. 確認: `curl --resolve <名前>.kigawa.net:443:<Cloudflare の IP> https://<名前>.kigawa.net/`(下の「確認の落とし穴」を参照)

**ionos の haproxy は触らない。** `mode tcp` は TLS を素通しするため、Host ヘッダーも見えない。Host や SNI で ionos から振り分ける必要は、ない。

## 触ってはいけない・気をつけること

| 変更 | 起きたこと |
|---|---|
| ionos の haproxy の `https_backend` を 443 以外にする(#500) | TLS 素通しの先が、平文のポートになり、Cloudflare の TLS が失敗して、`*.kigawa.net` が全部 525 |
| EasyTier の Secure Mode を、credential なしで有効にする(#503) | 全ピアが接続できず、オーバーレイが落ち、BGP が止まり、CI から 10.0.0.x に届かなくなった |
| k8s4 の `easytier_proxy_network`(サブネットプロキシ)に 10.0.0.0/24(や /32)を入れる(#513) | 全ピア(ionos・bao・runner)が `10.0.0.0/24 dev tun0 proto static metric 65535` を入れる。FRR は「kernel、distance 0、best」として採用し、BGP(distance 20)に勝たせる。ionos から 10.0.0.240 に届かず、525。/32 でも、ノード同士の通信を奪い、503・525 |
| 手元で `knotd` を起動する、`kresd.conf` を手で書き換える(k8s1) | 5353 の競合で Pod が落ち、公開 DNS に落ちた |

原則: 経路・DNS・ファイアウォールは、**変更の前に、現状と戻し方を記録し、変更のあとに、外部の経路で確認する**。カナリア(1 台、すぐ検証、悪化したら即ロールバック)で行う。

## 確認の落とし穴: 内部と外部で、経路が違う

main(自宅 LAN)の DNS は、内部の Knot を使い、`*.kigawa.net` を `10.0.0.240` に解決する。**普通の `curl https://<ホスト>/` は、Cloudflare を通らない**(障害に気づけない)。外部の経路は、Cloudflare の IP を指定して測る:

```bash
CF=104.21.25.176   # dig +short <ホスト> @1.1.1.1 の値でもよい
curl -s -o /dev/null -w '%{http_code}\n' --resolve opencode.kigawa.net:443:$CF https://opencode.kigawa.net/
```

連続して(5 秒おきに 20 回など)測る。経路が変わると、数十秒後に崩れることがある(#513 の `/32` の試験は、27 秒後に 503・525 が出た)。

## CI から 10.0.0.x へ届く経路

- 現在は、**WireGuard**(ランナー 172.31.254.21 → ionos wg0 → k8s4 wg1 → ノード)。確認済み(`ping`、TCP 22、`traceroute`)
- EasyTier 経由(`CI_EASYTIER`)は、既定で無効。サブネットプロキシが、上の表のとおり、経路を奪うため、安全に使えない
- 手元(main、LAN)からは、`./hardware/run.sh <node> apply` で、直接届く
- **`-target` で apply するときの注意**: `module.knot` など、`depends_on` を持つものは、`control_plane`(置き換え)を巻き込む。巻き込まれたくないときは、`plan` で確認してから使う
