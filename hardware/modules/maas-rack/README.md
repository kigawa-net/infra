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
| 時刻同期 | **`systemd-timesyncd` が削除され、`chrony` に置き換わる**(パッケージの依存)。**MAAS の rackd は、登録の際に `chrony.conf` を書き換え、上流の `server` / `pool` を消す**(`/etc/chrony/maas.conf` は、`local stratum 9 orphan` と `allow` だけ。Region の NTP の設定が空のため)。そのため、**`chrony` の起動と、MAAS が書き換えない `/etc/chrony/sources.d/ubuntu-pool.sources`(Ubuntu の pool。導入前と同じ上流)の設置を、最優先**にする(登録などの失敗で、時刻同期が無い状態に、ならないように) |
| bind9 | 入るが、**mask** する(`:53` は kresd が使う) |
| nginx | default サイトを外す(`:80` を空ける)。Rack の HTTP は、別の設定(`/var/lib/maas/http/nginx.conf`) |
| avahi | disable する |
| DHCP | `maas-dhcpd` / `maas-dhcpd6` は、パッケージの preset で enable になるので、**明示的に disable** する |
| 登録 | `maas-rack register --url <Region の URL>`。**secret は stdin で渡す**(引数に出さない)。**登録済みと判定するのは、`rackd.conf` に同じ URL があり、かつ、共有 secret のファイル(`/var/lib/maas/secret`)があるとき**(URL だけだと、登録が途中で失敗した状態を、見逃す)。登録の失敗では、後続を止めず、最後に失敗として終わる。**`maas-rack register` は `maas-rackd` を停止させる**ので、登録の後に、必ず、起動する |
| サービス | `maas-rackd`・`maas-http`・`maas-proxy`・`maas-syslog`・`maas-agent`・`chrony` を enable / start(`maas-http` 以下は、Region への登録まで起動しない) |

## secret の扱い

- 共有 secret は、**Region の `/var/lib/maas/secret` と同じ、32 桁の 16 進数**。Bitwarden の項目 **`maas-rack-shared-secret`**(プロジェクト `infra`)に保管した。ID は、ノードの変数 `maas_secret_bitwarden_id`(値ではなく ID)。
- **kigawa-net-k8s の `maas-secret`(Bitwarden の別の項目。88 文字)は、MAAS の共有 secret ではない**(`maas-rack register` が `Secret could not be decoded: Non-hexadecimal digit found` で失敗する)。取り違えない。
- 値は、ログにも、引数にも出さない(ノードの `main.tf` が `data "external"` で取得し、`sensitive()` で包んで module に渡す)。
- host に置くファイル `/tmp/maas-rack-secret` は、`0600` で作り、導入の成功・失敗にかかわらず、削除する。
- **Region の Pod を作り直しても、secret は変わらない**(MAAS が DB に保管する)。DB を作り直したときは、secret が変わるので、Bitwarden の項目を更新して、Rack を登録し直す。

## 失敗したとき・戻すとき

- 導入の途中で失敗すると、パッケージが中途半端な状態で残る。**自動では戻さない。** host で `/var/lib/maas-rack-module/maas-rack-rollback.sh` を、root で実行する。
  - 導入前のスナップショットとの差分だけを purge する(`autoremove` は使わない)。`systemd-timesyncd` を再インストールして戻し、nginx の default サイトと PPA も、元に戻す。
  - 検証では、導入前と同じパッケージ数、ポート、enabled なユニットに戻った。

## 未検証(コンテナでは、確認できないこと)

- ホストの AppArmor のプロファイル(dhcpd、squid、rackd、nginx、rsyslogd)。**`maas-syslog` は、Region(worker4)で、ホストの rsyslogd のプロファイルに拒否された**(Rack でも起きうる)。
- **k8s2 の `ufw` は、サービスは active だが、ファイアウォールは無効(`ufw status` は inactive)。** 導入後の k8s2 では、次が **LAN から届く**状態になる: TFTP(udp 69)は、**k8s2 の全アドレス(API の VIP、LB の VIP、クラスタのサービス IP の数百個)にバインドされる**、`maas-proxy`(tcp 8000)は `*:8000`、Rack の HTTP(tcp 5247 / 5248)、NTP(udp 123。MAAS の `maas.conf` の `allow` により、LAN に時刻を配る)。**この module は、ファイアウォールを変更しない。** 待ち受けの絞り込みは、DHCP の切り替えの前に、別の PR で行う。
- **Region の RPC(tcp 5250〜5253)が、Rack から届くこと**が前提。Region の Pod は、PID 1 の環境変数 `container=docker` が無いと、`/rpc/` に loopback だけを広告する(kigawa-net-k8s#401)。Rack は、Pod の IP(Flannel の `172.16.x.x`)の 5250〜5253 に直接 TCP で接続する(k8s のノードから届く)。
- `chrony` への切り替えで、host の時刻が飛ばないか。
- k8s4 の nginx は、標準の default サイトだけで、他の用途は無い(確認済み)。

## テスト

```bash
bash hardware/modules/maas-rack/test-maas-rack.sh
```

偽の `systemctl` / `apt-get` / `maas-rack` などで、`files/maas-rack-install.sh` を、使い捨てのディレクトリで検証する(実機の `/etc` には書かない)。secret が、引数・出力に出ないことも確認する。
