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
- 定義から外したトンネルは消える。残るトンネルは、作り直さず、その場で更新する(通信を切らない)。

## 何をするか
`/etc/gre-overlay/tunnels.conf` に定義を書き、`gre-overlay.service`(oneshot、`easytier.service` の後)が、起動時にトンネルを作る。`ip_gre` は `/etc/modules-load.d/gre-overlay.conf` で読み込む。止めると(`systemctl stop`)、トンネルを消す。

## このモジュールの範囲外
- ファイアウォール: GRE(プロトコル 47)の許可と、トンネル上の `179/tcp` の許可(`modules/overlay-firewall`、bao の ufw)。
- BGP の設定(`frr-overlay-peer`、`bgp-frr`)と、WireGuard の経路の切り替え。

## 確認
- `ip -d link show type gre`、`ping <トンネルの対向のアドレス>`
- `systemctl status gre-overlay.service`

## 戻し方
`tunnels = []` にして apply しても、トンネルは消えない(`null_resource` が destroy されるだけで、ノードの設定は残る)。手動で消す: `systemctl disable --now gre-overlay.service`(トンネルも消える)と、`/etc/gre-overlay/`・`/usr/local/sbin/gre-overlay`・`/etc/systemd/system/gre-overlay.service`・`/etc/modules-load.d/gre-overlay.conf` の削除。

## テスト
`bash hardware/modules/gre-overlay-tunnel/test-gre-overlay.sh`(偽の `ip`・`modprobe`・`systemctl` を使うオフラインのテスト。実機には触れない)
