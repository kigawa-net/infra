# FRR でルーティングする: Overlay 上の GRE トンネル方式の設計

**状態:** 設計(未実装)。実機は変更しない。
**関連:** PR #413(Overlay 上の eBGP)、[BGP の隣接を Overlay へ移す設計](easytier-bgp-migration-design.md)(§3.1 の問題が、実機で確認された)。

## 1. 背景

PR #413 は、bao-02/03 と Inuyama の control-plane(k8s4・k8s1・k8s2)の間に、EasyTier の Overlay(`10.250.0.0/24`)上で eBGP を張った。2026-11-03 の実機の確認で、次のことがわかった。

- BGP は `Established`、経路も入る。
- しかし、`10.0.0.x` や `192.168.1.x` 宛てのパケットは、`tun0` を出ても、返りが来ない。全ノードの `proxy_cidrs` が空で、EasyTier は、宛先が Overlay のアドレスでも `proxy_network` でもないパケットを運ばないため。
- このため、bao-02/03 には、`10.0.0.0/24 dev wg0 metric 10` の一時的な経路を入れて、復旧している(Terraform の管理外)。

EasyTier に `proxy_network` を足す方法もあるが、その場合、パケットをどの control-plane へ運ぶかは EasyTier が決める。FRR の経路(ECMP、障害時の切り替え)は、配送には効かない。**FRR が決めた経路どおりに届かせる**ために、本書の GRE 方式を採る。

## 2. 方式

bao-02/03 と、control-plane の各ノードの間に、**Overlay のアドレスを両端にした GRE トンネル**を張り、BGP はそのトンネルの中で動かす。

- 外側(GRE のパケット)の送信元と宛先は、Overlay のアドレス(`10.250.0.x`)。EasyTier が運ぶのは、これだけになるので、`proxy_network` は要らない。
- 内側(トンネルの中)は、LAN 宛てのパケットを、そのまま運ぶ。FRR が学んだ next-hop が、トンネルのインターフェース(`gre-*`)になり、パケットは、FRR の決めたノードへ届く。
- トンネルは、bao 2 台 × control-plane 3 台で、6 本。

```text
bao-02 (10.250.0.1) ── GRE ── k8s4 (10.250.0.11)   172.31.250.0/31
                    ── GRE ── k8s1 (10.250.0.12)   172.31.250.2/31
                    ── GRE ── k8s2 (10.250.0.13)   172.31.250.4/31
bao-03 (10.250.0.31) ── GRE ── k8s4 / k8s1 / k8s2  172.31.250.6/31, .8/31, .10/31
```

## 3. アドレス

トンネルの内側は、`172.31.250.0/24`(リポジトリで未使用。使用中は `172.31.252〜255`)から、1 本あたり `/31` を割り当てる。bao 側が偶数、control-plane 側が奇数。

| トンネル | bao 側 | control-plane 側 |
| --- | --- | --- |
| bao-02 ↔ k8s4 | `172.31.250.0` | `172.31.250.1` |
| bao-02 ↔ k8s1 | `172.31.250.2` | `172.31.250.3` |
| bao-02 ↔ k8s2 | `172.31.250.4` | `172.31.250.5` |
| bao-03 ↔ k8s4 | `172.31.250.6` | `172.31.250.7` |
| bao-03 ↔ k8s1 | `172.31.250.8` | `172.31.250.9` |
| bao-03 ↔ k8s2 | `172.31.250.10` | `172.31.250.11` |

インターフェース名は `gre-<相手>`(例: `gre-k8s4`、`gre-bao02`)。Linux の名前の長さ(15 文字)に収まる。

## 4. BGP

- neighbor を、Overlay のアドレスから、**トンネルのアドレス**に変える(`update-source` もトンネルのアドレス)。AS 番号は #413 のまま(bao-02 = 65041、bao-03 = 65042、control-plane = 65010)。
- `timers 3 9`(control-plane の iBGP と同じ)。Overlay やトンネルが切れたとき、約 9 秒で経路が撤回され、ECMP から外れる。これが、FRR で切り替える利点になる。
- import は、#413 と同じ(完全一致の `10.0.0.0/24` と `192.168.1.0/24`)。export は、何も出さない。

## 5. 送信元アドレスと戻りの経路

bao から LAN へ送るパケットの送信元は、既定ではトンネルのアドレス(`172.31.250.x`)になる。LAN 側の戻りが、このアドレスへの経路を持たないので、FRR で、**送信元を Overlay のアドレスに固定**する(ionos の `SET-SRC` と同じ手法。`route-map ... set src 10.250.0.1`)。

- 戻りは、worker の `10.250.0.0/24` の静的経路(#413 で追加済み)→ control-plane → Overlay の `tun0`(宛先は Overlay のアドレスなので運ばれる)→ bao。
- つまり、行きは GRE、戻りは Overlay の直接。非対称だが、どちらも、運ぶのは通常の IP パケット。bao 側の `rp_filter` は `2`(loose)なので、`tun0` に戻りが来ても落とさない。
- 戻りも GRE にそろえたい場合は、control-plane に、bao の Overlay のアドレスへの経路をトンネルへ向ける設定を足す。別途の検討とする。

## 6. 設計上の注意

### 6.1 MTU
EasyTier の `tun0` の MTU(既定 1380 の見込み。**実機で未確認**)から、GRE の 24 バイトを引く。トンネルの MTU は、`1300` 程度にして、control-plane で転送する TCP の MSS を、`gre-*` で絞る(`iptables -t mangle ... -o gre+ -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu`)。

### 6.2 ファイアウォール
- **bao-02/03(ufw):** `tun0` で、control-plane の Overlay のアドレスから、`gre`(プロトコル 47)を許可する。Overlay の送信元の deny より前に入れる(`insert 1`)。トンネル上の `179/tcp` は、`gre-*` のインターフェースと、トンネルのアドレスで許可する。
- **control-plane(iptables、`modules/overlay-firewall`):** Overlay の送信元(`10.250.0.0/24`)の INPUT は DROP が既定。GRE(プロトコル 47)の許可が要る。いまの許可リストは「ポート/プロトコル」の形式なので、ポートなしのプロトコルを許可できるように、モジュールを拡張する。
- #413 で足した「Overlay からの `179/tcp` の許可」は、トンネルへ移したあと、不要になる。外す。

### 6.3 トンネルの永続化
`systemd` の oneshot(`gre-overlay.service`)で、`ip tunnel add ... mode gre local <自分の Overlay> remote <相手の Overlay> ttl 64`、アドレス、MTU、`up` を行う。`easytier.service` の後に起動する。`terraform` の `null_resource` で入れる(新モジュール)。

### 6.4 経路の切り替えの順序
zebra は、距離 0 のカーネルの経路を、BGP(距離 20)より優先する。bao-02/03 に一時的に入れた `10.0.0.0/24 dev wg0`(WireGuard の経路)がある間は、BGP の経路は使われない。

1. トンネルと BGP を入れる。WireGuard の経路は、まだ残す(BGP の経路は使われない)。
2. トンネルの疎通を確認する(`ping -I`、一時的な `/32` の経路でトンネル経由の配送を試す)。
3. WireGuard の経路を外す(`wg_table_off`)。
4. ECMP で、control-plane のどれかを止めても、通信が続くことを確認する。

## 7. Terraform の変更(PR を分ける)

1. `modules/gre-overlay-tunnel`(新規。bao 側と control-plane 側の両方で使う。既定は無効)。
2. `modules/overlay-firewall` に、ポートなしのプロトコル(`gre`)の許可を足す。bao の ufw に、`gre` の許可を足す。
3. `frr-overlay-peer`(#413)の neighbor を、トンネルのアドレスにする。control-plane の `external_bgp_peers` も、トンネルのアドレスにする(**リストの末尾に足す**。添字で FRR のポリシー名が決まるため)。`timers 3 9` と `set src` を足す。
4. WireGuard の経路を外す(§6.4 の 2〜4 の確認の後)。

## 8. 先に確かめること(実機、Terraform なし)
- EasyTier が、GRE(プロトコル 47)を運ぶか。bao-02 と k8s1 の間に、手動で 1 本だけトンネルを張り、`ping` が通るかを見る(`ip tunnel del` で戻せる)。
- `ip_gre` のカーネルモジュールが、bao-02/03 と control-plane で使えるか。
- `tun0` の MTU。

## 9. 未決事項
- #413 との整理。#413 は、bao-02/03 の neighbor を Overlay のアドレスで張っている。本書の方式は、これをトンネルのアドレスに置き換える。#413 を先にマージするか、#413 を本方式に合わせて直すかを、決める。
- 戻りを GRE にそろえるか(§5)。
- ionos ↔ control-plane の BGP(WireGuard)を、同じ方式で移すか(本書は bao-02/03 だけを扱う)。
- bao は別の担当が作業中のため、実装の前に、担当と調整する。
