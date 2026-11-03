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

## 8. 実機の確認(2026-11-03、bao-02 ↔ k8s1。Terraform なし)

手動で、bao-02 と k8s1 の間に 1 本だけ GRE トンネル(`grechk`、`172.31.250.2` ↔ `.3`、MTU 1300)を張って確かめた。終わったら、トンネルと、`iptables` の INPUT の先頭に足した GRE の許可(`-i tun0 -p gre -s <相手>`)を消し、元に戻している。

| 項目 | 結果 |
| --- | --- |
| EasyTier が GRE を運ぶか | **運ぶ。** トンネルのアドレス間の `ping` が 3/3(約 141ms)。`tcpdump -i tun0` で、`GREv0` が両方向に見える |
| MTU | `tun0` の MTU は **1360**(見込みの 1380 より小さい)。1272 バイト(トンネルの MTU 1300 いっぱい、分割なし)の `ping` が 2/2 で通る。トンネルの MTU 1300 で足りる |
| `ip_gre` | bao-02・k8s1 の両方で読み込める |
| `rp_filter`(k8s1) | `all`・`default`・`tun0`・`grechk` のすべてで `2`(loose)。送信元 `10.250.0.1` のパケットを `grechk` で受けても落ちない |
| `FORWARD`(k8s1) | `ip_forward = 1`、ポリシーは `ACCEPT`(kube-proxy・flannel のチェーンはある) |
| トンネル経由で LAN へ | bao-02 に `/32` の一時的な経路を足し、送信元を `10.250.0.1` にして試した。`10.0.0.120`(k8s2)へ **4/4 で通る**(約 148ms)。k8s1 の `tcpdump` で、`grechk In` → `ens18 Out` を確認 |
| worker への戻り | **戻らない。** `192.168.1.130`(k8s-worker3)宛ては、`grechk In` → `ens18 Out` で k8s1 から LAN へ出るが、返事が来ない |

`10.0.0.120`(k8s2)が返せたのは、k8s2 自身が Overlay の `tun0` を持ち、`10.250.0.1` への戻りを `tun0` で直接返せるため。worker は Overlay に参加していないので、戻りの経路が要る。

### 8.1 worker の戻りの経路(2026-11-03 の更新: #413 のマージを反映)

`k8s-worker3` の plan(#413 のブランチ)で、`module.cluster_route` が `must be replaced` と出た。#413 が足した worker の静的経路(`extra_destination_cidrs` の `10.250.0.0/24`)は、その時点で未適用だった。このため、worker は、`10.250.0.1` 宛ての返事を、既定の経路(家庭用ルーター)へ送り、届かなかった。

その後、#413 が main にマージされ(2026-11-03 01:58)、9 モジュールの自動 apply がすべて成功した。`kubectl get nodes` も全ノード `Ready` だった。#413 には、本書の確認の後で、次のコミットが入っていた。

- **worker の静的経路**(`10.250.0.0/24` を control-plane へ): worker 4 台に適用された。
- **control-plane の MASQUERADE**(`modules/overlay-firewall` の `snat_source_cidr`、既定 `192.168.1.0/24`): LAN(Pod・node)から `tun0` へ出る通信の送信元を、その control-plane の Overlay のアドレスに書き換える。k8s1 に手動で入れて、worker1 の Pod から bao-02/03 の `8200/tcp` へ届くことを、#413 の作者が確認している(本書では未確認)。

向きごとに整理すると、次のとおり。

| 向き | 例 | #413 で解決するか |
| --- | --- | --- |
| LAN → Overlay(LAN が始める) | Pod → bao-02/03 | **解決。** MASQUERADE で、戻りが control-plane の Overlay のアドレスへ返る |
| Overlay → LAN(bao が始める) | bao-02/03 → bao-01 の VIP(Raft) | **未解決。** MASQUERADE は、LAN から出る向きだけ。宛先が `10.0.0.x` のパケットは、EasyTier が運ばない。**GRE 方式が必要** |

前回までの本書の方針は「SNAT は足さない」だった。LAN → Overlay の向きでは、#413 が SNAT で解決したので、この方針は古い。GRE 方式の対象は、Overlay → LAN の向きだけになる。

GRE 方式の戻りは、worker の静的経路(適用済み)と、`SET-SRC` による送信元の固定(§5)に頼る。

#### MASQUERADE と GRE の戻りの相互作用(仮説。未検証)
GRE で行きに通った control-plane と、戻りが通る control-plane が違うと(worker の gateway の選択は、BGP の ECMP とは独立)、戻りのパケット(送信元 `192.168.1.x`、宛先 `10.250.0.x`)が、別の control-plane の MASQUERADE に当たる(その control-plane には、この接続の conntrack がなく、新規の接続として扱われるため)。bao から見ると、戻りの送信元が、別の control-plane の Overlay のアドレスに変わり、接続が成立しない可能性がある。

GRE 方式の実装の前に、次のいずれかを確かめる。

1. 戻りが、必ず行きと同じ control-plane を通る(経路の固定、または、行きを、戻りの経路に合わせる)。
2. MASQUERADE の対象から、bao のアドレス宛てで、かつ GRE 経由で始まった接続の戻りを外す。

## 9. 未決事項
- #413 との整理。#413 は、bao-02/03 の neighbor を Overlay のアドレスで張っている。本書の方式は、これをトンネルのアドレスに置き換える。#413 を先にマージするか、#413 を本方式に合わせて直すかを、決める。
- 戻りを GRE にそろえるか(§5)。§8.1 のとおり、worker の静的経路は適用済み。LAN → Overlay の向きは、#413 の MASQUERADE で解決済み。GRE の戻りが MASQUERADE に当たる問題(§8.1 の仮説)を、先に確かめる。
- ionos ↔ control-plane の BGP(WireGuard)を、同じ方式で移すか(本書は bao-02/03 だけを扱う)。
- bao は別の担当が作業中のため、実装の前に、担当と調整する。
