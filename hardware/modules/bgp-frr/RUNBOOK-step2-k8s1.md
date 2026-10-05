# Step 2 手順書: k8s1 のみ BIRD → FRR に切り替える (#210)

**この手順書は計画であり、実行済みではない。** 実機の作業は、ユーザーの合図を受けてから行う。
対象は k8s1 (`10.0.0.103`) だけ。k8s2 / k8s4 は BIRD のまま(混在状態は #210 で許容されている)。

## 0. 前提と中止条件

実施する条件(すべて満たすこと):
- 全ノードが `Ready`、API VIP `10.0.0.100` が応答する、k8s2 / k8s4 の iBGP が Established。
- **k8s1 が kube-vip のリーダーではない**(`kubectl -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}'`)。リーダーなら、API VIP が数十秒途切れるので、別の時間に回すか、リーダーが移ってから行う。
- worker1 の I/O が落ち着いている(`/proc/pressure/io` の `full avg10` が 20% 未満)。
- ユーザーが同席し、ロールバックできる状態。

中止する条件(いずれか): 作業前の確認で想定外の差がある、`apt` で FRR を入れられない、API VIP が 60 秒以上途切れる、k8s1 から他ノードへ疎通できない。

## 1. 作業前の記録(読み取りのみ)

k8s1 で、切り替え前の状態を保存する(切り替え後に比較する)。

```
birdc show protocols
birdc show route export peer0   # 以下、peer1 も
ip -4 route show
ip -4 route show proto bird      # BIRD が入れた経路(persist で残る)
ip -4 addr show lo               # 10.0.0.53/32 があること
ss -ltn 'sport = :179'
```
BIRD の `crictl exec <bird> birdc ...` で取る(静的 Pod のため)。他の 2 台でも `birdc show route` を保存する。

## 2. 退避とロールバックの準備

```
cp /etc/bird/bird.conf /root/bird.conf.bak
cp /etc/kubernetes/manifests/bird.yaml /root/bird.yaml.bak   # manifests の外に置く
```
**自動ロールバック(デッドマンスイッチ)**を仕掛ける。何も確認できなくても、一定時間後に BIRD へ戻る:
```
systemd-run --unit=bgp-rollback --on-active=600 /root/rollback-bird.sh
```
`/root/rollback-bird.sh` の内容: `systemctl disable --now frr; ip route flush proto bgp; cp /root/bird.yaml.bak /etc/kubernetes/manifests/bird.yaml`。
切り替えが確認できたら `systemctl stop bgp-rollback.timer` で取り消す。

## 3. Terraform の変更(別 PR)

`hardware/k8s1/main.tf` の `module "bgp"` を `module "bgp_frr"` に置き換える。

```
module "bgp_frr" {
  depends_on = [module.control_plane]
  source     = "../modules/bgp-frr"

  host, ssh_user, ssh_private_key, sudo_password = (既存と同じ)

  bgp_router_id                   = var.server_ip      # 10.0.0.103
  bgp_local_as                    = var.bgp_local_as
  bgp_peers                       = var.bgp_peers      # ["10.0.0.120", "10.0.0.140"]
  advertised_vips                 = var.dns_vip != "" ? [var.dns_vip] : []
  redistribute_connected_prefixes = ["10.0.0.0/24", "10.0.0.100/32", "10.0.0.254/32"]
  enable_kube_vip_peer            = false
  ionos_nexthop_helper_interface  = ""                 # 下の注意を参照
  stop_bird                       = true
}
```
- **`ionos_nexthop_helper_interface` は空にする**。FRR モジュールは、非空を拒否する(zebra がカーネルに入れてしまうため)。k8s1 の BIRD 経路表では、`172.31.254.2/32` はカーネルにも `dev wg1` で既にあった(`kernel1` の経路)ので、補助経路が無くても next-hop は解決できるはず。**切り替え後に、`ip route get 172.31.254.2` で確認する**。
- `module.bgp` を消すと、Terraform は `null_resource.bird` を state から外すだけ(destroy の provisioner は無い)で、実機の BIRD は止まらない。止めるのは `stop_bird = true` の側。
- 適用経路: CI(main へのマージで自動 apply)は、k8s1 への SSH を WireGuard / BGP 経由で行う。BGP を切り替える最中に CI の接続が途切れるおそれがあるので、**手元から `terraform apply` するか、手順 4 を手で行ってから Terraform を追随させる**ほうが安全。

## 4. 切り替え(k8s1 のみ)

1. `apt` で `frr` を入れる。パッケージの postinst による自動起動を防ぐため、`systemctl mask --runtime frr.service` を先にする(モジュールの `setup_script` と同じ)。
2. `/etc/frr/daemons` で `bgpd=yes`、`/etc/frr/frr.conf` を配置(モジュールが生成する内容)。
3. BIRD の manifest を manifests ディレクトリから外す(`rm /etc/kubernetes/manifests/bird.yaml`。退避済み)。TCP 179 が空くまで待つ。
4. `systemctl unmask --runtime frr.service && systemctl enable --now frr`。
5. **BIRD が `persist` で残した経路を片付ける**: `ip -4 route show proto bird` で出た経路を確認し、`ip route flush proto bird`。BIRD は、他ノードからの BGP の経路(例: `0.0.0.0/0 via 10.0.0.140`)をカーネルに入れていたので、残ると k8s1 の経路が壊れる。

切り替え中は、k8s1 起点の経路(DNS VIP `10.0.0.53` は 3 台が広告するので影響は小さい)が一時的に取り下げられる。

## 5. 切り替え後の確認(すべて満たしたら成功)

- `vtysh -c 'show bgp ipv4 unicast summary'`: `10.0.0.120` と `10.0.0.140` が Established。
- `vtysh -c 'show bgp ipv4 unicast'`: `10.0.0.0/24`、`10.0.0.53/32` が自ノード起点、`172.31.254.0/24` と `10.255.10.12/32` が k8s4 経由(next-hop `10.0.0.140`)。
- `ip -4 route show` が作業前と同等: **デフォルト経路は `192.168.1.1`**(BIRD の時は BGP 由来の `0.0.0.0/0 via 10.0.0.140` が優先されていた。FRR では iBGP の距離が 200 で、kernel に負けるので、直るはず)。flannel の `172.16.x.0/24` は `flannel.1` 経由。
- **zebra が BGP の経路をカーネルに入れていること**: `ip route get 172.31.254.5` が `10.0.0.140` 経由になる。入っていなければ、**ロールバック**(隔離環境では確認できなかった項目)。
- 他ノードから見た k8s1: k8s2 / k8s4 の `birdc show route` に、`10.0.0.53/32` と `10.0.0.0/24` の k8s1 からの経路がある(next-hop `10.0.0.103`)。
- `dig +short k8s.kigawa.net @192.168.1.103` が `10.0.0.100`。`kubectl get nodes` が全 Ready。API VIP が応答。
- WireGuard と CI の経路: k8s1 から `172.31.254.2` への疎通、`wg show` の handshake が新しい。
- kube-vip のログ: BGP の接続エラーが出るのは想定内。VIP の付与はリーダー時に行われる。

成功したら、`systemctl stop bgp-rollback.timer` でロールバックを取り消し、30 分〜数時間様子を見る。問題が無ければ、k8s2 → k8s4 は別の手順書で行う(k8s4 は外部ピアを持つので最後)。

## 6. ロールバック

```
systemctl disable --now frr
ip route flush proto bgp
cp /root/bird.yaml.bak /etc/kubernetes/manifests/bird.yaml   # kubelet が BIRD の Pod を起動する
```
TCP 179 が FRR から空いたことを確認してから BIRD を戻す。戻したら、作業前の記録(手順 1)と比べる。Terraform の変更も戻す(`module "bgp"` を復活)。

## 7. 未検証の前提(実機で初めて分かること)

- zebra が BGP の経路をカーネルに入れるか(隔離環境では確認できなかった)。
- BIRD(k8s2 / k8s4)と FRR(k8s1)の iBGP が、タイマーの違い(FRR の hold 180 秒 / BIRD の 240 秒)で問題なく張れること。
- kube-vip の挙動(BGP のピアが無くても、VIP を保持すること)。ソースでは確認済み。
- `redistribute connected` が、`10.0.0.100/32`(kube-vip の保持時)を広告すること。
