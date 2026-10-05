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

- iBGP は全受信、helper `/32` 以外を広告し next-hop-self。kube-vip は loopback の passive multihop、受信 next-hop 書換、全広告拒否。外部ピアは ge/le なし prefix-list で完全一致し、空リストは route-map の全拒否になる。全 eBGP に双方向ポリシーがあるため `bgp ebgp-requires-policy` を維持する。
- 外部 `local_as` がプロセス AS と異なる場合は `local-as ... no-prepend replace-as`。余分なプロセス AS の付加を避ける判断で、eBGP 専用。AS loop 判定や複数 local-AS 間の再広告は BIRD の独立 protocol と完全同一とは限らず、実経路で確認する。[FRR BGP](https://docs.frrouting.org/en/latest/bgp.html)
- VIP は loopback `/32` と `network <vip>/32`、`bgp network import-check` を使い、blackhole/static route を追加しない。不要な blackhole による転送破壊を避ける一方、zebra RIB に同じ経路がないと広告されず、BIRD の常設 static と違ってアドレス消失時に広告停止し得る。loopback 経路の認識は対象版で要検証。VIP 削除時に古い loopback アドレスが残る挙動は既存スクリプトと同じ。
- syslog 出力、IPv4 unicast の明示的な有効化/ポリシー設定。neighbor のセッション属性は FRR の文法に従って router 階層に置く。設定変更は systemd restart のため全セッションが一時切断される。

## 未決事項と推奨

- **direct / kernel learn:** zebra の OS 経路認識と BGP 再広告は別。現状 `redistribute connected` / `redistribute kernel` は入れない。BIRD で広告していた直結/kernel 経路が減る可能性がある。必要 prefix を棚卸しし、WireGuard や他ノード由来の経路を混ぜない許可リスト付き再配布を検証してから追加する。
- **kernel export filter:** BIRD の `172.31.254.2/32` 除外に対応して zebra の `ip protocol bgp route-map` で exact `/32` を拒否し、その他を許可する。iBGP の広告拒否とは別の kernel 導入制御。対象 FRR で実際に FIB へ入らず他の BGP 経路は入ることを接続前に検証する。static helper は別 protocol なので、この BGP filter だけでは止まらない。[zebra filtering](https://docs.frrouting.org/en/latest/zebra.html#zebra-route-filtering)
- **helper:** `ip route 172.31.254.2/32 <iface>` を機械的に移すと zebra が kernel に入れ、より詳細な `/32` が中継経路を上書きし、WireGuard AllowedIPs/送信元検査で返信を落とし得る。まず helper を作らず既存経路で解決できるか確認する。`hardware/k8s2/main.tf` の `extra_post_up` は既に `ip route add 172.31.254.2/32 dev %i` を持つが、実ホストの存在・影響は未確認。k8s4 の直結 `/30`、他ノードの next-hop 書換や別解決方式も比較し、必要なら static 向け zebra filter を含め検証する。FRR 内だけの helper を推測で実装しない。
- **停止時の経路:** BIRD の `persist` と zebra の既定動作は同じではない。zebra は `--retain` を指定しない限り終了時に自身の経路を削除する。停止・再起動・ロールバック時の残存経路と収束を確認する。[zebra 起動オプション](https://docs.frrouting.org/en/latest/zebra.html#invoking-zebra)
- **タイマー/版依存:** 指示どおり timers は設定しない。ただし [FRR traditional](https://docs.frrouting.org/en/latest/basic.html#profiles) の既定 keepalive/hold は 60/180 秒、[BIRD](https://bird.network.cz/doc/bird-6.html) は hold 240 秒、keepalive は hold の 1/3。同値とは保証できず、対象 BIRD/FRR 版とネゴシエーション結果を確認する。apt パッケージ版は固定していないため、構文・next-hop 解決・経路選択の実機比較も移行条件とする。特に kube-vip の受信 route-map が自ノード router-id を next-hop にする経路について、FRR の自己 next-hop 判定・RIB/FIB 採用と VIP 疎通を検証する。
