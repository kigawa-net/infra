# bgp-frr (Issue #210 Step 1)

apt の FRR をホストの `frr.service` (zebra + bgpd) で動かすモジュール。まだノードには接続しない。以下の未決事項を解消してから移行する。

## 入力

`bgp-bird` と同じ `host`, `ssh_user`, `ssh_private_key`, `sudo_password`, `bgp_router_id` が必須。鍵・パスワードは sensitive。任意入力は `bgp_local_as=65000`, `bgp_peers=[]`, `kube_vip_as=65001`, `advertised_vips=[]`, `external_bgp_peers=[]`, `ionos_nexthop_helper_interface=""`。外部ピアの object は BIRD と同じで `local_pref` は省略可/null。`bird_image` は廃止し `stop_bird=false` を追加した。

helper 変数は互換性のため残すが、**非空値は validation で拒否する**。既存 k8s1/k8s2 の入力を無検証で移すことはできない。空値では helper 経路を作成しない。

## 移行・ロールバック (後続 Step で実施)

1. 対象 OS の apt FRR バージョン、設定構文、既存 BIRD/BGP/kernel 経路、VIP と WireGuard の到達性を隔離環境で比較する。BIRD manifest/config は manifests ディレクトリ外へ退避し、復旧経路を確保する。
2. 未決事項を解消後、1 ノードずつ BIRD の再配置を止めて FRR を接続する。`stop_bird=true` は FRR 起動前に `/etc/kubernetes/manifests/bird.yaml` を削除し、TCP 179 解放を待つ。apt による先行起動も抑制する。既定 false は BIRD に触れず、競合時は失敗する。
3. `show bgp ipv4 unicast summary`、受信/広告経路、kernel FIB、VIP 疎通と再起動後を比較する。`local-vip.service` とスクリプトは BIRD と同内容で共有する。
4. 戻す場合は **先に `sudo systemctl disable --now frr` で FRR を止め、TCP 179 の解放を確認**して、退避した BIRD config/manifest を復元する。BIRD の経路再学習と疎通を確認する。VIP と共有サービスは削除しない。Terraform のモジュール削除だけでは provisioner の配置物は元に戻らない。

## BIRD との差分・採用方針

- iBGP は全受信、helper `/32` 以外を広告し next-hop-self。kube-vip との BGP は、既定で**出力しない**(`enable_kube_vip_peer = false`。下の「隔離環境での検証結果」参照)。外部ピアは ge/le なし prefix-list で完全一致し、空リストは route-map の全拒否になる。全 eBGP に双方向ポリシーがあるため `bgp ebgp-requires-policy` を維持する。
- 外部 `local_as` がプロセス AS と異なる場合は `local-as ... no-prepend replace-as`。余分なプロセス AS の付加を避ける判断で、eBGP 専用。AS loop 判定や複数 local-AS 間の再広告は BIRD の独立 protocol と完全同一とは限らず、実経路で確認する。[FRR BGP](https://docs.frrouting.org/en/latest/bgp.html)
- VIP は loopback `/32` と `network <vip>/32`、`bgp network import-check` を使い、blackhole/static route を追加しない。不要な blackhole による転送破壊を避ける一方、zebra RIB に同じ経路がないと広告されず、BIRD の常設 static と違ってアドレス消失時に広告停止し得る。loopback 経路の認識は対象版で要検証。VIP 削除時に古い loopback アドレスが残る挙動は既存スクリプトと同じ。
- syslog 出力、IPv4 unicast の明示的な有効化/ポリシー設定。neighbor のセッション属性は FRR の文法に従って router 階層に置く。設定変更は systemd restart のため全セッションが一時切断される。

## 隔離環境での検証結果(2026-10-05、Docker 上の FRR 8.4.7 / 10.2.1 と gobgp)

k8s4 相当の構成(iBGP 1、IONOS 役 1、kube-vip 役 1)で経路交換を確認した。ノードには触れていない。

確認できたこと:
- 外部ピアへは、許可リストの `10.0.0.0/24` 相当だけが広告された(VIP や iBGP の経路は出ない)。
- 外部ピアの import は許可リストが効き、許可外(`8.8.8.0/24`)は iBGP の仲間にも届かない。
- iBGP の仲間には、直結の再配布(`10.0.0.0/24` 相当)、`network` の VIP `/32`、IONOS から学んだ経路(next-hop は自ノード = next-hop-self)が届いた。
- `network <vip>/32` は、`lo` にそのアドレスがあれば valid / best になる(アドレスが無いと広告されない)。

**確認できたこと(悪い方): 同一ホストの kube-vip と FRR の BGP は、今の構成では動かない。**
- `127.0.0.2`(BIRD での自分側アドレス)は、FRR では BGP の自分側アドレスに使えない: `nexthop_set failed, resetting connection - intf (Unknown)`。`lo` に `127.0.0.2/32` を足しても同じ。
- 自ノードのインターフェースにあるアドレスは、neighbor に指定できない: `Can not configure the local system as neighbor`。
- 動的ネイバー(`bgp listen range`)と `lo` の非 127 アドレス(例: `10.99.99.1` / `.2`)なら、セッションは確立する。ただし、kube-vip(gobgp)が送る next-hop は自ノードのアドレスなので、更新は破棄される: `DENIED due to: martian or self next-hop`。`bgp allow-martian-nexthop` を足しても解消しない。
- 結論: kube-vip の BGP 経由の広告は、FRR 側では受け取れない。API VIP `10.0.0.100/32` は、BIRD の経路表でも、保持ノードのインターフェースに**直結**として存在した。`redistribute_connected_prefixes` で伝搬できる想定(**要検証**)。

未検証:
- ~~kube-vip が、BGP のピアがつながらない状態でも、VIP を保持ノードのインターフェースに付けるか。~~ **ソース(kube-vip v0.8.9、`pkg/cluster/service.go` の `vipService`)で確認済み**: リーダーになると、まず `AddIP(false)` で VIP をインターフェースに付与し、そのあとで `bgpServer.AddHost` を呼ぶ。ピアが設定されていて接続できないだけなら、`AddHost` は成功し、kube-vip は止まらず VIP を保持する。リーダーを失うと `DeleteIP` で VIP が消え、直結経路も消えるので、FRR の広告も取り下げられる。
  - **注意**: ピアの環境変数(`bgp_peeraddress`)を消してはいけない。`NewBGPServer` はピアが 0 件だとエラーを返し、`bgpServer` が `nil` のまま `AddHost` が呼ばれて落ちる可能性がある。現状の `bgp_peeraddress=127.0.0.2` は残す(FRR 側は接続を拒否するだけで、kube-vip のログが増えるのみ)。
  - 実機では未確認。ステップ 2 の k8s1 の切り替えで、VIP が保持され、`redistribute connected` で広告されることを確認する。
- zebra が BGP の経路をカーネルに入れるか。検証用コンテナでは、zebra が「FIB に入れた」と表示するのに、`ip route` に反映されなかった(コンテナの権限の制約と思われ、設定の問題とは断定できない)。`ip protocol bgp route-map BGP-TO-KERNEL` の動作も、同じ理由で未検証。

## 未決事項と推奨

- **direct / kernel learn(実機で棚卸し済み、2026-10-05):** k8s1 / k8s2 / k8s4 の BIRD を `birdc show route export <peer>` で確認した。
  - **`redistribute connected` は必須**: k8s4 が IONOS / Oracle へ広告するのは `10.0.0.0/24`(`direct1` = 直結)だけ。API VIP `10.0.0.100/32`(kube-vip 保持ノードのインターフェースに直結として存在)と、ゲートウェイ VIP `10.0.0.254/32`(keepalived)も `direct1` として iBGP に載っている。再配布しないと、外部への広告と VIP の伝搬が止まる。→ `redistribute_connected_prefixes`(許可リスト、完全一致)で再配布する。ノードごとの指定は `["10.0.0.0/24", "10.0.0.100/32", "10.0.0.254/32"]`。
  - **`redistribute kernel` は入れない**: BIRD は kernel の経路(flannel の `172.16.x.0/24`、デフォルト経路 `0.0.0.0/0 via 192.168.1.1`)も iBGP に流している。その結果、k8s1 では `0.0.0.0/0` が k8s4 経由(BGP の優先度 100 が kernel の 10 に勝つ)、`172.16.x.0/24` が flannel ではなく BGP 経由になっている。これは意図した設計ではなく、#241 の「BGP からデフォルト経路を配布しない」とも合わない。FRR では流さない。**移行すると、この副作用は消える**ので、移行後に各ノードのデフォルト経路が `192.168.1.1` 直行になること、flannel 経由で Pod 宛が届くことを確認する。
  - **要検証**: `192.168.1.53/32`(k8s4 の `lo`)と `172.31.254.11/32` / `172.31.254.12/32`(k8s1 / k8s2 の `wg1` のアドレス)は、`direct1` として iBGP に載っている。必要かどうかは未確認で、今回の許可リストには入れていない。`172.31.254.0/30`(k8s4 の `wg1`)も同様。
- **kernel export filter:** BIRD の `172.31.254.2/32` 除外に対応して zebra の `ip protocol bgp route-map` で exact `/32` を拒否し、その他を許可する。iBGP の広告拒否とは別の kernel 導入制御。対象 FRR で実際に FIB へ入らず他の BGP 経路は入ることを接続前に検証する。static helper は別 protocol なので、この BGP filter だけでは止まらない。[zebra filtering](https://docs.frrouting.org/en/latest/zebra.html#zebra-route-filtering)
- **helper:** `ip route 172.31.254.2/32 <iface>` を機械的に移すと zebra が kernel に入れ、より詳細な `/32` が中継経路を上書きし、WireGuard AllowedIPs/送信元検査で返信を落とし得る。まず helper を作らず既存経路で解決できるか確認する。`hardware/k8s2/main.tf` の `extra_post_up` は既に `ip route add 172.31.254.2/32 dev %i` を持つが、実ホストの存在・影響は未確認。k8s4 の直結 `/30`、他ノードの next-hop 書換や別解決方式も比較し、必要なら static 向け zebra filter を含め検証する。FRR 内だけの helper を推測で実装しない。
- **停止時の経路:** BIRD の `persist` と zebra の既定動作は同じではない。zebra は `--retain` を指定しない限り終了時に自身の経路を削除する。停止・再起動・ロールバック時の残存経路と収束を確認する。[zebra 起動オプション](https://docs.frrouting.org/en/latest/zebra.html#invoking-zebra)
- **タイマー/版依存:** 指示どおり timers は設定しない。ただし [FRR traditional](https://docs.frrouting.org/en/latest/basic.html#profiles) の既定 keepalive/hold は 60/180 秒、[BIRD](https://bird.network.cz/doc/bird-6.html) は hold 240 秒、keepalive は hold の 1/3。同値とは保証できず、対象 BIRD/FRR 版とネゴシエーション結果を確認する。apt パッケージ版は固定していないため、構文・next-hop 解決・経路選択の実機比較も移行条件とする。特に kube-vip の受信 route-map が自ノード router-id を next-hop にする経路について、FRR の自己 next-hop 判定・RIB/FIB 採用と VIP 疎通を検証する。
