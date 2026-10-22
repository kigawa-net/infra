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
| ファイアウォール | **Rack のポートを、LAN の送信元かつ、このホストの LAN のアドレス宛てだけに絞る**(専用の chain `MAAS-RACK`を `INPUT` の先頭から呼ぶ。`ufw` は使わない。systemd の oneshot `maas-rack-firewall.service` で、再起動後も適用)。詳細は、下の「待ち受けの絞り込み」 |
| avahi | disable する |
| DHCP | `maas-dhcpd` / `maas-dhcpd6` は、パッケージの preset で enable になるので、**明示的に disable** する |
| 登録 | `maas-rack register --url <Region の URL>`(**Region 専用の VIP の URL `http://10.0.0.244:5240/MAAS`**。`maas-agent` が、この URL のホストの tcp 5271(Temporal)に接続する。Ingress の URL では、`maas-agent` が `connection refused` で、クラッシュを繰り返す)。**secret は stdin で渡す**(引数に出さない)。**登録済みと判定するのは、`rackd.conf` に同じ URL があり、かつ、共有 secret のファイル(`/var/lib/maas/secret`)があるとき**(URL だけだと、登録が途中で失敗した状態を、見逃す)。登録の失敗では、後続を止めず、最後に失敗として終わる。**`maas-rack register` は `maas-rackd` を停止させる**ので、登録の後に、必ず、起動する |
| サービス | `maas-rackd`・`maas-http`・`maas-proxy`・`maas-syslog`・`maas-agent`・`chrony` を enable / start(`maas-http` 以下は、Region への登録まで起動しない) |

## secret の扱い

- 共有 secret は、**Region の `/var/lib/maas/secret` と同じ、32 桁の 16 進数**。Bitwarden の項目 **`maas-rack-shared-secret`**(プロジェクト `infra`)に保管した。ID は、ノードの変数 `maas_secret_bitwarden_id`(値ではなく ID)。
- **kigawa-net-k8s の `maas-secret`(Bitwarden の別の項目。88 文字)は、MAAS の共有 secret ではない**(`maas-rack register` が `Secret could not be decoded: Non-hexadecimal digit found` で失敗する)。取り違えない。
- 値は、ログにも、引数にも出さない(ノードの `main.tf` が `data "external"` で取得し、`sensitive()` で包んで module に渡す)。
- host に置くファイル `/tmp/maas-rack-secret` は、`0600` で作り、導入の成功・失敗にかかわらず、削除する。
- **Region の Pod を作り直しても、secret は変わらない**(MAAS が DB に保管する)。DB を作り直したときは、secret が変わるので、Bitwarden の項目を更新して、Rack を登録し直す。

## 待ち受けの絞り込み(ファイアウォール)

Rack を入れると、次が、ホストの**全アドレス**(API の VIP、LB の VIP、`kube-ipvs0` のサービス IP の数百個を含む)で待ち受ける。control-plane の `INPUT` は `ACCEPT` で、**`ufw` は、サービスは active でも、ファイアウォールは無効**(`ufw status` が inactive)なので、LAN から全部届く。

| ポート | プロセス | 用途 |
|---|---|---|
| udp 69 | rackd(TFTP。全アドレスにバインド) | PXE のブート |
| tcp 5248 | nginx(Rack の HTTP) | ブートイメージ |
| tcp/udp 5247 | rsyslogd | 機械のログ |
| tcp 3128 / 8000 | squid(maas-proxy) | 機械のパッケージの取得 |
| udp 123 | chronyd(MAAS の `maas.conf` の `allow`) | 機械への時刻の配布 |
| tcp 5249 | rackd の内部 HTTP | **nginx(5248)が `localhost:5249` に proxy_pass するだけ**(外には、不要) |

`ufw` を有効にすると、control-plane の既定が変わり危険なので、**専用の chain `MAAS-RACK` だけ**を、`INPUT` の先頭から呼ぶ(`ci-ssh-forward` などと同じ、systemd の oneshot + iptables の方式)。対象は上のポートだけで、SSH、etcd、kube-apiserver などには触れない。

1. `lo` からは許可。
2. **送信元が `lan_cidr`(既定 `192.168.1.0/24`)で、宛先が `lan_address`(このホストの LAN のアドレス。k8s2 は `192.168.1.20`、k8s4 は `192.168.1.120`)のときだけ**許可。
3. それ以外(VIP 宛て、クラスタのサービス IP 宛て、Pod 経由、LAN の外)は DROP。
4. `tcp 5249` は、`lo` 以外すべて DROP。

- **`lan_address` は必須**(`server_ip`(クラスタの LAN のアドレス)とは別)。無いと、Terraform の `precondition` と、導入のスクリプトの両方が、導入を中止する(ファイアウォール無しで、Rack を公開しない)。
- LAN の `192.168.1.0/24` の全ホストに、許可を出す(試験機や、他の端末を含む)。さらに絞るなら、DHCP を MAAS が担う段階で、MAAS が管理するサブネットだけにする。
- **DHCP(udp 67)と、failover(tcp 647 / 7911)の許可を、先に入れてある**(DHCP を、まだ、有効にしないので、待ち受けが無く、実機への影響は無い)。
  - **udp 67**: クライアントのブロードキャスト(送信元 `0.0.0.0:68` → `255.255.255.255:67`)、LAN からのブロードキャスト、LAN から `lan_address` 宛ての unicast(更新)を許可。それ以外(VIP 宛てなど)は DROP。
  - **tcp 647 / 7911**(ISC dhcpd の failover の peer 間と、OMAPI): **`dhcp_peer_address`(もう一方の Rack の LAN のアドレス)から `lan_address` 宛て**だけ許可。k8s2 の相手は `192.168.1.120`、k8s4 の相手は `192.168.1.20`。空なら、許可しない。LAN の他のホストには、許可しない。
  - 使い捨ての Ubuntu 24.04 の本物の `iptables` で、相手の Rack からだけ 647 / 7911 に届き、LAN の一般ホストと LAN 外は遮断されること、udp 67 の unicast とブロードキャストが通ること、VIP 役のアドレス宛てと LAN 外は遮断されることを確認した。
  - DHCP の切り替えの手順は、[docs/maas-dhcp-cutover.md](../../../docs/maas-dhcp-cutover.md)。
- 止める・戻す: `systemctl stop maas-rack-firewall`(`remove` で chain を消す)。
- **検証**: 偽の `iptables` によるテスト(ルールの内容、冪等性、`remove`)と、**使い捨ての Ubuntu 24.04 の本物の `iptables`** で、LAN からは LAN のアドレス宛てだけ届き、VIP 役のアドレス宛て、LAN 外、`5249`(`lo` 以外)は遮断され、対象外のポートは通ることを確認した(tcp と udp)。

## 失敗したとき・戻すとき

- 導入の途中で失敗すると、パッケージが中途半端な状態で残る。**自動では戻さない。** host で `/var/lib/maas-rack-module/maas-rack-rollback.sh` を、root で実行する。
  - 導入前のスナップショットとの差分だけを purge する(`autoremove` は使わない)。`systemd-timesyncd` を再インストールして戻し、nginx の default サイトと PPA も、元に戻す。
  - 検証では、導入前と同じパッケージ数、ポート、enabled なユニットに戻った。

## 未検証(コンテナでは、確認できないこと)

- ホストの AppArmor のプロファイル(dhcpd、squid、rackd、nginx、rsyslogd)。**`maas-syslog` は、Region(worker4)で、ホストの rsyslogd のプロファイルに拒否された**(Rack でも起きうる)。
- **Region の RPC(tcp 5250〜5253)が、Rack から届くこと**が前提。Region の Pod は、PID 1 の環境変数 `container=docker` が無いと、`/rpc/` に loopback だけを広告する(kigawa-net-k8s#401)。Rack は、Pod の IP(Flannel の `172.16.x.x`)の 5250〜5253 に直接 TCP で接続する(k8s のノードから届く)。
- `chrony` への切り替えで、host の時刻が飛ばないか。
- k8s4 の nginx は、標準の default サイトだけで、他の用途は無い(確認済み)。

## テスト

```bash
bash hardware/modules/maas-rack/test-maas-rack.sh
```

偽の `systemctl` / `apt-get` / `maas-rack` などで、`files/maas-rack-install.sh` を、使い捨てのディレクトリで検証する(実機の `/etc` には書かない)。secret が、引数・出力に出ないことも確認する。
