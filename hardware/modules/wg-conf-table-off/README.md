# wg-conf-table-off

既存の wg-quick の設定(`/etc/wireguard/<iface>.conf`)に、`Table = off` と、必要な `PostUp` を、**インターフェースを再起動せずに**追記する module(kigawa-net/infra#238)。

## 背景
wg-quick は、起動のたびに、`AllowedIPs` の全てを、カーネルの経路として追加する(`ip route add`)。

**k8s4 の `wg1`(IONOS)と `wg-oracle`(Oracle)は、どちらの `AllowedIPs` にも `10.255.10.12/32`(Soichiro)がある。** 再起動の起動順で `wg1` が先に経路を取ると、`wg-oracle` の `ip route add` が `File exists` で失敗し、wg-quick が**インターフェースごと消す**。**2026-10-18 14:21 UTC のノードの再起動から 4 日間、`wg-oracle` が死んでいた**(Soichiro への主経路(Oracle 経由、約 12 ms)が無く、Karmada の etcd #2 が `unhealthy`)。`wg1` は、起動のたびに、`172.31.254.0/24` の on-link の経路(BGP の経路より優先される誤った経路)も作っていた。

## 対処
- `Table = off`: `AllowedIPs` からの経路の自動追加を止める。**`AllowedIPs` 自体(暗号鍵ルーティング)は変わらない。**
- 必要な経路だけを、`PostUp` の `ip route replace` で、明示的に入れる(**`replace` なので、衝突しない**)。`wg-oracle` は `10.255.10.12/32`(変数 `oracle_wireguard_routes`)。`wg1` は、BGP が学習するので、追加の経路は要らない。
- 使い捨てのコンテナの**本物の wg-quick**で、パッチ前は `File exists` で `wg-oracle` が消え(本番と同じ)、パッチ後は、どちらの起動順でも、両方が起動し、経路が `wg-oracle` に付くことを確認した。

## 挙動
- **インターフェースは再起動しない**(再起動すると、IONOS との接続と、CI の SSH 経路が切れる恐れがある)。設定は、**次に wg-quick が起動するとき**(ノードの再起動)から効く。
- 冪等。設定ファイルには、**秘密鍵が入っている**ので、**バックアップは作らず**、中身を出力しない。検証(`Table = off` が 1 行、`PrivateKey` の行が残る)に通ったときだけ、同じディレクトリの一時ファイルから、`mv` で置き換える(権限 600)。
- `Table` に `off` 以外の値が入っているときは、上書きせず、失敗する。設定ファイルが無いインターフェースは、スキップする。
- k8s4 の `null_resource.ionos_wireguard` / `oracle_wireguard`(設定の生成元)にも、同じ内容を入れてある(新しく作るときのため)。**それらの `triggers` は変えていない**ので、稼働中の設定には、再実行されない(再実行すると、`wg1` が再起動する)。稼働中の設定には、この module が追記する。

## テスト
`bash hardware/modules/wg-conf-table-off/test-wg-conf-table-off.sh`(27 件。`networkd-keep-foreign` も含む)。
