# maas-rack

MAAS 3.6 の Rack コントローラーを、host に deb で直接インストールする module(kigawa-net/infra#207、[docs/maas-design.md](../../../docs/maas-design.md))。

- Rack は k8s に載せず、control-plane の **k8s2(DHCP の primary)と k8s4(secondary)** に入れる。k8s1 は、メモリが足りないので入れない。
- **この module は、DHCP を有効にしない。** DHCP の切り替え(スイッチの DHCP を止めて、MAAS の DHCP に一本化)は、LAN 全体に影響するので、別の段階で行う。
- `enabled = false`(既定)では、何も作らない。**1 台ずつ、別の PR で `maas_rack_enabled = true` にする**(マージで、CI が自動 apply する)。

## 導入で起きること(host に対して)

使い捨ての Ubuntu 24.04 で検証した(`files/maas-rack-install.sh`)。

| 項目 | 内容 |
|---|---|
| パッケージ | `ppa:maas/3.6` を追加し、`apt-get install --no-upgrade maas-rack-controller`。約 208 パッケージが入る。**既存パッケージのアップグレードが計画に含まれるときは、中止する** |
| 事前チェック | メモリの空きが `min_available_mb`(既定 2000)未満なら、中止する |
| 時刻同期 | **`systemd-timesyncd` が削除され、`chrony` に置き換わる**(パッケージの依存)。導入後に、時刻のずれを確認する |
| bind9 | 入るが、**mask** する(`:53` は kresd が使う) |
| nginx | default サイトを外す(`:80` を空ける)。Rack の HTTP は、別の設定(`/var/lib/maas/http/nginx.conf`) |
| avahi | disable する |
| DHCP | `maas-dhcpd` / `maas-dhcpd6` は、パッケージの preset で enable になるので、**明示的に disable** する |
| 登録 | `maas-rack register --url <Region の URL>`。**secret は stdin で渡す**(引数に出さない)。登録済み(`rackd.conf` に同じ URL)なら、やり直さない |
| サービス | `maas-rackd`・`maas-http`・`maas-proxy`・`maas-syslog`・`maas-agent`・`chrony` を enable / start(`maas-http` 以下は、Region への登録まで起動しない) |

## secret の扱い

- Region との共有 secret は、Bitwarden(kigawa-net-k8s の `maas-secret` と同じもの)から、`data "external"` で取得する(ノードの `main.tf`)。値は、ログにも、引数にも出さない。
- host に置くファイル `/tmp/maas-rack-secret` は、`0600` で作り、導入の成功・失敗にかかわらず、削除する。

## 失敗したとき・戻すとき

- 導入の途中で失敗すると、パッケージが中途半端な状態で残る。**自動では戻さない。** host で `/var/lib/maas-rack-module/maas-rack-rollback.sh` を、root で実行する。
  - 導入前のスナップショットとの差分だけを purge する(`autoremove` は使わない)。`systemd-timesyncd` を再インストールして戻し、nginx の default サイトと PPA も、元に戻す。
  - 検証では、導入前と同じパッケージ数、ポート、enabled なユニットに戻った。

## 未検証(コンテナでは、確認できないこと)

- ホストの AppArmor のプロファイル(dhcpd、squid、rackd、nginx、rsyslogd)。**`maas-syslog` は、Region(worker4)で、ホストの rsyslogd のプロファイルに拒否された**(Rack でも起きうる)。
- k8s2 の `ufw`(active)で、Rack のポート(67/68・69 udp、5247 udp、5248・8000 tcp)と、failover のポート(647・7911 tcp)の許可が要る。**この module は、ufw を変更しない。** 登録後に `ss` で待ち受けを確認してから、別の PR で足す。
- `chrony` への切り替えで、host の時刻が飛ばないか。
- k8s4 の nginx は、標準の default サイトだけで、他の用途は無い(確認済み)。

## テスト

```bash
bash hardware/modules/maas-rack/test-maas-rack.sh
```

偽の `systemctl` / `apt-get` / `maas-rack` などで、`files/maas-rack-install.sh` を、使い捨てのディレクトリで検証する(実機の `/etc` には書かない)。secret が、引数・出力に出ないことも確認する。
