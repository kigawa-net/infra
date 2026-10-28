# EasyTier の Relay 切替と Direct への復帰の実測手順

設計書 `docs/network-vpn-architecture-design.md` §4.1「EasyTier の Relay 切替と直接 P2P への復帰は、採用バージョンで実測する必要がある」に対応する。**この文書は手順書であり、実測はまだ行っていない。** 結果は §6 に追記し、設計書 §4.1.1 に反映する。

- 対象: EasyTier v2.6.4。ionos(`10.250.0.2`、`74.208.55.86`)、bao-02 / ServerCheap(`10.250.0.1`、`207.231.111.196`)、bao-03 / host-hye1(`10.250.0.31`、`143.203.220.195`)
- 実施者: ユーザー(各ノードへの SSH、ufw の変更を伴う本番操作のため。Claude は実行しない)

## 1. 何を確かめるか

| # | 問い | 設計上の意味 |
| --- | --- | --- |
| A | 公開 Peer が 1 台止まっても、残りのノード間の Direct 接続は保たれるか | 「特定の 1 台だけに依存しない」(§4.1) |
| B | Direct の経路が使えなくなったとき、公開 Peer 経由の Relay に切り替わるか。切替にかかる時間は | §4.3「Peer が到達可能なまま Relay へ切り替わっても BGP は Down と認識しない」の前提 |
| C | Direct の経路が戻ったとき、Relay から Direct へ自動で復帰するか。復帰にかかる時間は | 同上。Relay のまま戻らないと、遅延が増えたままになる |
| D | Relay 時の遅延・損失は、Direct と比べてどれだけ悪化するか | §4.3「Relay 時の遅延増加を監視し、別の WireGuard 経路へ切り替えるポリシーを検討」の閾値の根拠 |

NAT 配下のノード(Inuyama・Soichiro)は、まだ Overlay に参加していない。**本物の NAT 越えの Relay は、この実測の対象外**(NAT 配下のノードを組み込んだ後に、別途行う)。ここでは、bao-02 ↔ bao-03 の直接経路を ufw で塞ぎ、ionos 経由の Relay を人為的に起こす。

## 2. 前提と実施してよい条件

- [ ] **OpenBao が未初期化(sealed)で、Raft が動いていないこと。** 初期化後は、bao-02 ↔ bao-03 の Overlay 通信が Raft を運ぶため、経路を切るとクォーラムに影響しうる。**初期化後に行う場合は、この手順をそのまま使わず、Raft への影響を見直すこと。**
- [ ] 3 台の `easytier-cli peer` で、互いが `p2p` で見えること(実測の起点)
- [ ] 実施中に、bao-02 ↔ bao-03 の Overlay を使う本番の通信が無いこと
- [ ] 各ノードの SSH を、Overlay 以外(公開アドレス)で張れること。**手順で塞ぐのは 11010 だけで、SSH は塞がない**
- [ ] ionos の SSH は専用の鍵(`bws` の `ssh_key_bitwarden_id`)が要る。使い終わったら鍵の一時ファイルを必ず消す

## 3. 準備(計測用の端末を 3 つ用意する)

```bash
# bao-02 で、bao-03 の状態を 1 秒ごとに記録する(切替・復帰の時刻を測る)
ssh root@207.231.111.196 'while true; do printf "%s " "$(date +%T)"; easytier-cli peer | grep "10.250.0.31" | tr -s " " | cut -c1-90; sleep 1; done'

# bao-02 で、bao-03 への ping を打ち続ける(損失と遅延を測る)
ssh root@207.231.111.196 'ping -i 0.2 10.250.0.31 | while read l; do echo "$(date +%T) $l"; done'
```

`easytier-cli peer` の `cost` 列が、直接なら `p2p`、中継なら `relay(2)` のように出る。**v2.6.4 の実際の表記は、最初に実機で確認する**(この文書の `p2p` / `relay` という語は仮定)。

## 4. 手順

### 実験 A: 公開 Peer(ionos)の停止と復帰

1. ionos で `systemctl stop easytier`(ホストや WireGuard は止めない。**止めるのは `easytier` だけ**)
2. 計測端末で、bao-02 ↔ bao-03 が `p2p` のままか、ping が途切れないかを 2 分間見る
3. ionos で `systemctl start easytier`
4. bao-02 / bao-03 の `easytier-cli peer` に、ionos(`10.250.0.2`)が `p2p` で戻るまでの時間を測る

期待: 手順 2 では、bao-02 ↔ bao-03 は直接つながっているので、影響を受けない。

### 実験 B・C・D: 直接経路の遮断と復帰

1. 起点を記録する: bao-02 ↔ bao-03 の RTT(`ping -c 50 -i 0.2 10.250.0.31`)と、`easytier-cli peer` の表記
2. **bao-02 で**、bao-03 の公開アドレスとの 11010 を塞ぐ(双方向)
   ```bash
   ufw insert 1 deny out to 143.203.220.195 port 11010 comment 'relay-test'
   ufw insert 1 deny in from 143.203.220.195 to any port 11010 comment 'relay-test'
   ```
3. **bao-03 で**、bao-02 の公開アドレスとの 11010 を塞ぐ(双方向)
   ```bash
   ufw insert 1 deny out to 207.231.111.196 port 11010 comment 'relay-test'
   ufw insert 1 deny in from 207.231.111.196 to any port 11010 comment 'relay-test'
   ```
4. 既存の接続は、ufw の `before.rules`(ESTABLISHED)で通り続けるため、**bao-02 の `easytier` を再起動して、接続を張り直させる**(`systemctl restart easytier`)。この時刻を T0 とする
5. bao-02 で、bao-03 が `relay` になるまでの時間(T0 から)と、そのときの RTT・損失を測る(**B・D**)
   - `relay` にならず `p2p` のままなら、EasyTier が 11010 以外のポートで hole punching している。**その場合は、手順 2・3 の `port 11010` を外し(`deny out to <IP>` / `deny in from <IP>`)、再度 T0 から測る。SSH は公開アドレスで張っているので、塞ぐと切れる点に注意し、先に別の端末で接続を確保しておく**
6. Relay のまま 5 分間、ping の損失と遅延を記録する(**D**)
7. **遮断を解く**: 手順 2・3 のルールを、同じ指定で削除する(下のロールバックを参照)。この時刻を T1 とする
8. bao-02 で、bao-03 が `p2p` に戻るまでの時間(T1 から)を測る(**C**)。**5 分待っても戻らない場合は、`systemctl restart easytier` で戻るかも確認し、「自動復帰しない」と記録する**

## 5. ロールバック(中断したとき、終わったとき)

```bash
# bao-02
ufw delete deny out to 143.203.220.195 port 11010
ufw delete deny in from 143.203.220.195 to any port 11010
# bao-03
ufw delete deny out to 207.231.111.196 port 11010
ufw delete deny in from 207.231.111.196 to any port 11010
# 確認(`relay-test` が残っていないこと)
ufw status numbered | grep relay-test
```

- 手順 5 で `port 11010` を外した場合は、その指定のルールを同じ指定で消す
- ionos の `easytier` を止めたままにしない(`systemctl is-active easytier` が `active` であること)
- 終了後、3 台の `easytier-cli peer` が、実験前と同じ `p2p` に戻っていること、ufw のルールが元に戻っていることを確認する

## 6. 結果の記録欄(実測後に追記する)

| 項目 | 結果 |
| --- | --- |
| `easytier-cli peer` の表記(Direct / Relay) | |
| A: ionos 停止中の bao-02 ↔ bao-03 | |
| A: ionos 停止後、再開して戻るまでの時間 | |
| B: 直接経路の遮断から Relay になるまでの時間 | |
| C: 遮断の解除から Direct に戻るまでの時間 | |
| D: Direct の RTT / loss | |
| D: Relay の RTT / loss | |
| 想定外の挙動 | |

### 判断の目安(案。実測を見て決める)

- 切替(B)・復帰(C)が数十秒〜数分で自動に起きること
- Relay の RTT が、Direct の何倍になるか。**§4.3 の「別の WireGuard 経路へ切り替えるポリシー」の閾値は、この値から決める**
- 自動復帰しない、または切替に数分以上かかる場合は、監視(Exporter)で「Relay のまま」を検知する必要が高くなる(設計書 §8)
