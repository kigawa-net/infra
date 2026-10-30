# frr-overlay-peer

bao-02 / bao-03 に FRR(`frr.service`、`bgpd`)を入れ、Inuyama の control-plane(k8s4・k8s1・k8s2)と、**EasyTier のオーバーレイ(10.250.0.0/24)上で eBGP** を張るモジュール。bgp-frr(k8s 専用、iBGP・外部ピアの設計)は流用せず、小さく別に作った。

## 目的

Inuyama の Pod から bao-02/03(overlay の 10.250.0.1 / 10.250.0.31)へ届くようにし、bao-02/03 からは 10.0.0.0/24(クラスタ LAN、bao-01 の VIP)と 192.168.1.0/24(worker の LAN)を overlay 経由で返せるようにする。

## 経路の流れ

- Pod → (Flannel MASQUERADE) → worker の node IP(192.168.1.x)→ core router VIP(192.168.1.200、control-plane の master)→ control-plane の tun → overlay → bao。
- bao → 10.0.0.0/24 / 192.168.1.0/24 → BGP で学んだ経路(tun0 の 10.250.0.x 経由)→ control-plane → LAN。

## 設定(テンプレート: `templates/frr.conf.tpl`)

- `router bgp <local_as>`(bao-02 = 65041、bao-03 = 65042)、`bgp router-id` と `update-source` は overlay の IP。
- neighbor は control-plane の overlay の IP(10.250.0.11 / .12 / .13)、`remote-as 65010`(control-plane は `local-as 65010 no-prepend replace-as` を名乗る)。
- **import**: `ip prefix-list OVERLAY-IN` で完全一致の 10.0.0.0/24 と 192.168.1.0/24 だけを permit。それ以外は `deny 100`。
- **export**: out の route-map を置かない。`bgp ebgp-requires-policy` により、何も広告しない。
- `bgp ebgp-requires-policy` と `no bgp default ipv4-unicast` を有効にする。

## 適用手順(bao-02 / bao-03 の変数)

1. `frr_overlay_enabled = true` で適用する(FRR だけ。`wg_table_off` は false のまま)。`easytier_overlay_allow` に `179/tcp` が入るので、easytier が一度再起動する(overlay が数秒落ちる)。
2. 確認: `vtysh -c 'show bgp ipv4 unicast summary'` で 3 neighbor が `Established`。`vtysh -c 'show bgp ipv4 unicast'` で 10.0.0.0/24 と 192.168.1.0/24 が、overlay の next-hop(10.250.0.x)で入っている。`ip route show 10.0.0.0/24` は、まだ `dev wg0`(wg の経路)のまま(`wg_table_off` 前なので正常)。
3. `wg_table_off = true` で適用する(wg0 が再起動する。数秒、WireGuard の経路が切れる)。bao-02 → 確認 → bao-03 の順に 1 台ずつ。
4. 確認: `ip route get 10.0.0.240` が `dev tun0` を出る。`ip route show 172.31.254.0/24` が `dev wg0` で残っている。`wg show wg0` の AllowedIPs が変わっていない。

wg_table_off の変更は、wireguard モジュールの `table_off` と `extra_post_up`(`ip route replace 172.31.254.0/24 dev %i`)として入る。AllowedIPs は変えない(kigawa-net/infra#238 の教訓: AllowedIPs を縮めると、非対称経路で障害が出る)。

## ロールバック

BGP だけを止める場合(経路は WireGuard に戻る):

1. `wg_table_off = false` で適用する(wg0 が再起動し、10.0.0.0/24 の wg の経路が戻る)。
2. `frr_overlay_enabled = false` で適用する(この変数で作られた `module.frr_overlay` は、destroy されるが、`frr.service` の停止は、この null_resource では行わない。下の手動手順で止める)。
3. 手動で止める場合: `systemctl disable --now frr`。`/etc/frr/frr.conf` は残ってよい。

control-plane 側は、`external_bgp_peers` から bao-02/03 の peer を外し、`easytier_overlay_allow` から `179/tcp` を外すと、bgp-frr が reload する(peer は末尾に足したので、添字は既存のものと変わらない)。

## 未確認のリスク

- bao-02/03 は、overlay が落ちると 10.0.0.0/24 に届かない(wg の経路を外したため)。bao-02/03 → bao-01 の Raft は overlay 前提になる。
- control-plane が overlay から TCP 179 を受けるようになる(FRR は設定した neighbor 以外の接続を受けないが、overlay の他のノードからの SYN は届く)。
- 192.168.1.0/24 を iBGP に流す(control-plane の `redistribute_connected_prefixes`)。各 control-plane は LAN に直結しているので、connected が優先される。

## テスト

`bash hardware/modules/frr-overlay-peer/test-frr-overlay-peer.sh`(terraform のみ。描画した設定の prefix-list・neighbor・out の route-map を確認する)。
