# gre-overlay-ufw

bao 側(ufw を使うホスト)で、GRE トンネル(`modules/gre-overlay-tunnel`)のための受信を許可するモジュール。設計は [docs/frr-gre-overlay-design.md](../../../docs/frr-gre-overlay-design.md) §6.2。

- `tun0` から、相手の Overlay のアドレスの **gre**(プロトコル 47)。`ufw insert 1` で先頭に入れる(Overlay の deny より前に評価させるため)。
- トンネル(`gre-<name>`)の上の、相手のトンネルのアドレスからの **179/tcp**。

`modules/easytier`(共有モジュール)は変えない。置き換えると EasyTier が再起動し、OpenBao が seal されるため、ufw の規則だけを足す別のモジュールにしてある。control-plane(iptables)の gre の許可は、`modules/overlay-firewall` の `overlay_allow` に `gre` を足す。

## 使い方

```hcl
module "gre_overlay_ufw" {
  source = "../modules/gre-overlay-ufw"

  host            = var.host
  ssh_user        = var.ssh_user
  ssh_private_key = data.external.ssh_key[0].result.value
  sudo_password   = data.external.sudo_password[0].result.value

  peers = [
    { name = "k8s4", overlay_address = "10.250.0.11", tunnel_address = "172.31.250.1" },
  ]
}
```

- `peers` が空(既定)なら、何もしない。
- 規則は ufw のコメント(`gre-overlay-<name>-gre`、`gre-overlay-<name>-bgp`)で見つける。再実行しても重複しない。
- 定義が不正なら、先に全部検証して、何も足さずに止める。

## 確認
`ufw status | grep gre-overlay-`

## 戻し方
足した規則は、`peers` を空にしても自動では消えない。手動で消す(番号を確認してから)。

```bash
ufw status numbered | grep gre-overlay-
ufw delete <番号>
```

## テスト
`bash hardware/modules/gre-overlay-ufw/test-gre-overlay-ufw.sh`(偽の `ufw` を使うオフラインのテスト。実機には触れない)
