# easytier モジュール

ノードへ [EasyTier](https://github.com/EasyTier/EasyTier) を導入し、systemd サービス `easytier.service` として起動する。
設計は `docs/network-vpn-architecture-design.md` §4.1。既存の WireGuard・FRR・BGP には触れない(Overlay `10.250.0.0/24` 上で完結する)。

## 使い方

```hcl
module "easytier" {
  source           = "../modules/easytier"
  host             = var.host
  ssh_user         = var.ssh_user
  ssh_private_key  = local.ssh_key
  sudo_password    = local.sudo_password
  easytier_version = "2.6.4"        # 採用バージョン(docs/network-vpn-architecture-design.md §4.1)
  easytier_sha256  = "<自分で計算した zip の SHA-256>"
  network_name     = "kigawa-net"
  network_secret   = local.easytier_network_secret   # bws_get_value で取得する
  overlay_address  = "10.250.0.11/24"
  peers            = ["tcp://<ServerCheap>:11010", "tcp://<IONOS>:11010"]  # 公開ノードを 2 台以上
}
```

組み込み済み(2026-10-29 時点の `easytier_enabled` の既定): ionos・bao-02・bao-03・k8s4・k8s2 は true、k8s1 は false。採用バージョンは v2.6.4。Relay 切替と Direct への復帰の実測は未実施(`docs/easytier-relay-test.md`)。新しいノードに組み込む前に、Secret を Bitwarden に登録すること。

## 動作

- zip をダウンロードし、`easytier_sha256` と照合する。一致しなければ何も入れずに失敗する。
- 同じバージョンが入っていれば、ダウンロードを省いて設定だけ更新する。
- 設定は `/etc/easytier/easytier.toml`(ディレクトリ 0700、ファイル 0600)。Secret はプロセスの引数にも unit にも出さない。

## テスト

```bash
bash hardware/modules/easytier/test-easytier-setup.sh   # 偽の curl / systemctl を使うオフラインテスト
```
