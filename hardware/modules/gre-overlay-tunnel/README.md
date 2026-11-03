# gre-overlay-tunnel

EasyTier の Overlay(`10.250.0.0/24`)のアドレスを両端にした GRE トンネルを作り、再起動後も残すモジュール。設計は [docs/frr-gre-overlay-design.md](../../../docs/frr-gre-overlay-design.md)。

EasyTier は、宛先が Overlay のアドレスでも `proxy_network` でもないパケットを運ばない。GRE の外側を Overlay のアドレスにすると、EasyTier が運ぶのは Overlay のアドレス宛てだけになり、トンネルの中の LAN 宛てのパケットは、FRR(BGP)が決めた経路どおりに届く。

## 使い方

```hcl
module "gre_overlay" {
  source = "../modules/gre-overlay-tunnel"

  host            = var.server_ip
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key.result.value
  sudo_password   = data.external.sudo_password.result.value

  tunnels = [
    { name = "k8s4", local = "10.250.0.1", remote = "10.250.0.11", address = "172.31.250.0/31" },
    { name = "k8s1", local = "10.250.0.1", remote = "10.250.0.12", address = "172.31.250.2/31" },
  ]
}
```

- `tunnels` が空(既定)なら、何もしない。
- インターフェース名は `gre-<name>`(例: `gre-k8s4`)。
- `mtu` の既定は 1300(Overlay の `tun0` が 1360、GRE のヘッダが 24 バイト)。
- 定義から外したトンネルとその許可は消える。残るトンネルは、作り直さず、その場で更新する(通信を切らない)。
- `address` は `/31` だけ(相手のアドレスは、`/31` のもう片方。`172.31.250.0/31` なら相手は `.1`)。

## 何をするか
`/etc/gre-overlay/tunnels.conf` に定義を書き、`gre-overlay.service`(oneshot、`easytier.service` の後。`PartOf=easytier.service` で、easytier の再起動に連動する)が、起動時にトンネルを作る。`ip_gre` は `/etc/modules-load.d/gre-overlay.conf` で読み込む。止めると(`systemctl stop`)、トンネルと許可を消す。

## ファイアウォールの許可(`manage_firewall`、既定 true)
トンネルごとに、`iptables` の INPUT の先頭へ、2 つの許可を入れる(ufw・`modules/overlay-firewall` の DROP より前)。

| 許可 | ルール |
| --- | --- |
| GRE(外側のパケット) | `-i <overlay_iface> -p gre -s <相手の Overlay のアドレス> -j ACCEPT` |
| トンネルの中の BGP | `-i gre-<name> -p tcp --dport 179 -s <相手のトンネル内のアドレス> -j ACCEPT` |

- `modules/overlay-firewall`(control-plane)は、`easytier.service` の起動のたびに、DROP のチェインへの飛ばし先を INPUT の先頭へ入れ直す。許可が 2 番目に押されないよう、`gre-overlay.service` を easytier の再起動に連動させ、許可を先頭へ入れ直す。
- 共有モジュール(`modules/overlay-firewall`、`modules/easytier`)は変えない。変えると、control-plane・ionos・bao の自動 apply の対象になるため。
- ufw のあるホスト(bao)でも、ufw の `iptables` のルールより前に入るので、ufw のルールは触らない。
- フィルタのないホストでは、`manage_firewall = false` でよい。

## このモジュールの範囲外
- BGP の設定(`frr-overlay-peer`、`bgp-frr`)と、WireGuard の経路の切り替え。
- TCP の MSS の絞り込み(control-plane で転送する TCP を、`gre-*` で絞る。設計書 §6.1)。

## 確認
- `ip -d link show type gre`、`ping <トンネルの対向のアドレス>`、`iptables -S INPUT | head`(GRE と 179/tcp の許可が先頭にあるか)
- `systemctl status gre-overlay.service`

## 戻し方
`tunnels = []` にして apply しても、トンネルと許可は消えない(`null_resource` が destroy されるだけで、ノードの設定は残る)。手動で消す: `systemctl disable --now gre-overlay.service`(トンネルと許可も消える)と、`/etc/gre-overlay/`・`/usr/local/sbin/gre-overlay`・`/etc/systemd/system/gre-overlay.service`・`/etc/modules-load.d/gre-overlay.conf` の削除。

## テスト
`bash hardware/modules/gre-overlay-tunnel/test-gre-overlay.sh`(偽の `ip`・`modprobe`・`systemctl` を使うオフラインのテスト。実機には触れない)
