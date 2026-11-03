# BGP の隣接を WireGuard から EasyTier の Overlay へ移す設計

**状態:** 設計(未実装)。実機には何も変更していません。
**位置づけ:** [全体ネットワーク・VPN基盤設計書](network-vpn-architecture-design.md) の §4.2(FRR/BGP)の移行手順を、具体化するものです。

## 1. 目的と方針

WireGuard(`172.31.254.0/24` ほか)で張っている eBGP の隣接を、EasyTier の Overlay(`10.250.0.0/24`)上へ移します。

- WireGuard は、Overlay 上の隣接が安定したと確認できるまで外さない。
- 最初は、**並走させて観測するだけ**にする。経路の選択は変えない。
- 切り替え(WireGuard の隣接を外す)は、本書の範囲外とする。観測の結果を見て、別の設計で決める。

## 2. 現状(2026-10-30 に、リポジトリで確認した内容)

| 項目 | 内容 |
| --- | --- |
| ionos の隣接 | wg0 経由の k8s4・k8s2、専用リンク(`wg-gw4`・`wg-gw2`)経由の k8s4・k8s2、Oracle、Soichiro |
| local-preference | 専用リンクの k8s4 が 200、k8s2 が 150、wg0 経由は 1〜99(最低)。Oracle 経由の Soichiro 向けは 200 |
| ionos の送信元 | BGP で学んだ経路は、`SET-SRC` で送信元を ionos の wg0 のアドレスに固定している(etcd #3、HAProxy、Karmada が同じアドレスを使うため) |
| k8s4 の eBGP | `external_bgp_peers`(ionos、Oracle)。`10.0.0.0/24` を広告する |
| `bgp-frr` | k8s1・k8s2・k8s4 で共通のモジュール。変更すると、3 台の FRR が同時に再読み込みされる |
| EasyTier | ionos(`10.250.0.2`)、bao-02(`.1`)、bao-03(`.31`)、k8s4(`.11`)、k8s1(`.12`)、k8s2(`.13`)が参加済み。`proxy_network` は未設定 |

## 3. 問題

### 3.1 EasyTier は、`proxy_network` がないと LAN 宛てを運ばない

BGP のセッションを `10.250.0.x` で張っても、学んだ経路(`10.0.0.0/24` など)の宛先は、Overlay のアドレスではありません。ionos が `tun0` へ送っても、EasyTier は、宛先が Overlay のアドレスでも `proxy_network` でもないパケットを捨てます。

→ Inuyama 側のノードに、`proxy_network`(サブネットプロキシ)の設定が要ります。`modules/easytier` に、まだありません。

### 3.2 戻りの通信が、非対称になるおそれがある

ionos は、送信元を wg0 のアドレス(`172.31.254.2`)に固定しています。行きが Overlay になっても、Inuyama 側の戻りは、`172.31.254.2` への経路(WireGuard)に向かいます。

→ 送信元を、Overlay のアドレス(`10.250.0.2`)に変えるか、行きと戻りの両方を揃えるかを、切り替えの設計で決める必要があります。並走の段階では、この経路を使わない(セッションだけを張る)ので、影響しません。

### 3.3 経路の選択が変わるおそれ

セッションを足すと、同じ prefix の経路が増えます。`local-preference` を最低にしないと、いまの経路より優先される可能性があります。

### 3.4 Overlay 側のファイアウォール

- k8s1・k8s2・k8s4 は、`EASYTIER-OVERLAY` チェーンが Overlay からの受信を DROP する。BGP 用に `179/tcp` の許可が要る(`easytier_overlay_allow`)。
- ionos は、ufw の Overlay 拒否の後に、`179/tcp` の許可を入れる。送信元は、相手の Overlay のアドレスだけにする。

## 4. 並走の構成

```text
ionos(10.250.0.2, AS65030)  ── eBGP(tcp/179、Overlay) ──  k8s4(10.250.0.11, AS65000)
```

- 隣接は、まず ionos ↔ k8s4 の 1 本だけにする(k8s2 は、これが安定してから)。
- ionos 側は、`local-preference` を、既存の wg0 の隣接より小さくする(例: 1。wg0 経由が 1〜99 の範囲のため、実際の値は実装の時点の設定を見て決める)。
- k8s4 側は、広告する経路を、既存の `export_prefixes`(`10.0.0.0/24`)と同じにする。取り込みは、`import_prefixes = []` にする。
- 経路をカーネルに入れない状態を確認する(下の §5)。

## 5. 確認の基準

並走を始めた後、次の 3 つを満たすこと。

1. `vtysh -c 'show bgp summary'` で、Overlay の隣接が `Established` になる。
2. `ip route get 10.0.0.103`(ionos)など、既存の宛先の経路が、並走の前後で変わらない。
3. 24 時間で、`Established` のまま、フラップがない。

## 6. 実装の順序(PR を分ける)

1. `modules/easytier` に `proxy_network`(既定は空)を足す。これだけでは、何も変わらない。
2. k8s4 の `easytier_overlay_allow` に `179/tcp` を足す。ionos に `179/tcp` の許可を足す。
3. ionos と k8s4 に、Overlay の隣接を足す。ionos 側は `local-preference` を最低にする。
4. §5 の確認。

## 7. 未決事項

- `proxy_network` を設定するノードと範囲(`10.0.0.0/24` だけか、`192.168.1.0/24` も含めるか)。複数のノードが同じ範囲を出すときの、EasyTier の経路の選択。
- 戻りの通信の送信元(§3.2)。etcd #3、HAProxy、Karmada が、どちらのアドレスを使うか。
- Oracle・Soichiro の隣接を、Overlay に移すか(本書は ionos ↔ k8s4 だけを扱う)。
- bao-02・bao-03 は別の担当が作業中のため、本書の範囲に含めない。
