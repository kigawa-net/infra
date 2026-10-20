# MAAS 本番導入の設計(infra#207 / kigawa-net-k8s#220)

2026-10-20 時点の設計案。決定事項、調べて分かった事実、未検証の点を分けて書く。

## 決定事項(kigawa)
1. **既存の LAN(`192.168.1.0/24`)で、MAAS が DHCP / PXE を担う(案 Q)。** PXE 用の専用 VLAN は作らない。(10/19)
2. **PostgreSQL は、Ceph RBD(`rook-ceph-rbd`)のまま。**(10/19)
3. **Rack は k8s に載せず、control-plane のホストに、deb で直接インストールする。**(10/20)
4. 専用ノードへの隔離はしない。Region と PostgreSQL は、今のまま k8s 上。

## 現状
- Rack: k8s の `maas-rack` DaemonSet(ラベル付きのノードが 0 台で、一度も動いていない)。**この設計で廃止する。**
- Region: Deployment 1(`privileged`、systemd 実行、Docker イメージは Ubuntu 22.04 + MAAS 3.5)。PostgreSQL: StatefulSet 1、Ceph RBD 20Gi。Ingress は `maas.kigawa.net`(haproxy)。
- 既存の DHCP は、スイッチ(`192.168.1.1`)。

## 調べて分かった事実(2026-10-20。使い捨ての Ubuntu 24.04 コンテナで確認。実機には触れていない)
1. **MAAS 3.5 の PPA には、Ubuntu 24.04(noble)用のリリースが無い。** control-plane は 24.04(k8s1: 24.04.2、k8s2: 24.04.2、k8s4: 24.04.3)なので、**Rack は 3.6 以降が必須**(PPA `ppa:maas/3.6`、候補は 3.6.6)。noble の標準アーカイブには `maas-rack-controller` が無い。
2. **Rack は、Region より新しいバージョンにできない**(Rack が新しい構成は非対応)。Region は今 3.5。**先に Region を 3.6 に上げる必要がある。** DB の migration を伴うので、backup が先。
3. **`maas-rack-controller` を control-plane に入れると、次のものが一緒に入る / 変わる(`apt-get install -s` の結果)。**
   - **`systemd-timesyncd` が削除され、`chrony` に置き換わる**(時刻同期の方式が変わる)。
   - **`bind9` が入る**(Rack の依存。パッケージのスクリプトが、起動する)。control-plane は kresd が `:53` を特定のアドレスで使っているので、**衝突する**。
   - **`nginx` が入る**(既定のサイトが `:80` を待ち受ける)。ほかに `avahi-daemon`、`rsyslog`、`isc-dhcp-server`(`maas-dhcp`)、`maas-proxy`(squid)、`maas-agent`、`libvirt-clients`、多数の python3 パッケージ。
4. 使用予定のポート(67/69/123 udp、5247 udp、5248/8000 tcp)は、k8s1・k8s2・k8s4 のすべてで空いている。53 は kresd が使用中(上の bind9 と衝突)。80 の使用状況は、未確認。
5. メモリの空き: k8s1 は 541MB / 4.9GB で、足りない(避ける)。k8s2 は約 10GB / 15.9GB、k8s4 は約 6.5GB / 9.9GB。
6. Rack が Region に登録するための URL は、Ingress の `http(s)://maas.kigawa.net/MAAS`(ホストの kresd で解決できる。クラスター内の Service 名 `maas-region-svc...svc.cluster.local` は、ホストからは解決できない)。

## 設計

### 1. DHCP / PXE(案 Q)
- Rack が、DHCP(67/udp)、TFTP(69/udp)、HTTP(5248/tcp)を提供する。
- **スイッチの DHCP を止め、MAAS の DHCP に一本化する。** 既存の端末の DHCP も MAAS が配る。範囲・ゲートウェイ(`192.168.1.1`)・DNS(kresd)・予約を、現在のスイッチの設定と同じにする。**切り替え前に、スイッチの設定を、控える。**
- **Rack が止まると、LAN 全体の DHCP が止まる。** 緩和: リース時間を長めに、スイッチの設定を保存して戻せるように、切り替えは段階を分ける。

### 2. Rack の配置(control-plane の 2 台のホストに直接。2026-10-20 の決定)
- **ノード: k8s2(DHCP の primary)と k8s4(DHCP の secondary)の 2 台に入れる。** k8s1 には入れない(メモリの空きが 541MB / 4.9GB と少なく、逼迫するため)。
- **DHCP の冗長化は、MAAS の仕様上、VLAN ごとに「primary と secondary の 2 台」まで**(ISC dhcpd の failover。MAAS は、1 つの VLAN に 2 台の Rack を割り当てる)。2 台で、この上限を使い切る。
  - 片方が落ちると、もう片方が DHCP を継続する(自動)。その間は冗長性が無い。
  - **3 台目への自動の昇格は、MAAS の標準機能には無い。** 3 台目を入れない構成なので、問題にならない。代わりに、**片方が落ちたらアラートを出し、復旧を急ぐ**(運用手順に書く)。
  - 2 台の DHCP が、互いに通信する必要がある(ISC の failover の peer ポート。既定は 647/tcp と、MAAS の制御用の 7911/tcp)。control-plane の ufw と、ホスト間の経路で、通るか、**未検証**。
- **導入は、1 台ずつ(k8s2 → k8s4)。** 同時に変えない(control-plane の quorum と、VIP・BGP・kresd への影響を避けるため)。1 台入れるごとに、etcd の health、kube-vip、BGP、kresd、時刻同期を確認してから、次へ進む。
- **IaC は、`maas_rack_enabled`(既定 `false`)を、ノードごとに切り替える。** マージすると CI が、変更のあるノードに自動で apply するので、既定を `false` にして、1 ノードずつ、別の PR で `true` にする。
- **k8s2 の事情:** API の VIP の保持者になりやすく、IONOS の予備ゲートウェイでもある。**k8s4 は IONOS の主ゲートウェイ。** どちらも役割が重い。
- **隔離しない決定の結果:** Rack(DHCP / TFTP / proxy / nginx など、ネットワークに露出するサービス)が、control-plane(etcd・apiserver・BGP・WireGuard)と同じホストに載る。侵害時の影響が大きい。docs に明記する。
- インストールは **IaC(Terraform の module `hardware/modules/maas-rack`、既存の module と同じ SSH + null_resource の方式)**で行う。手動の `apt install` はしない。
  - `apt-get install --no-upgrade`(既存の frr・haproxy などを、上げて再起動させない。#285 の教訓)。
  - **`policy-rc.d` で、インストール中のサービスの自動起動を止める**。インストール後、必要なものだけ明示的に起動する。
  - **bind9 は、mask する**(Rack では使わない。MAAS の DNS は Region 側)。**kresd との衝突を避ける。**
  - **nginx の既定サイト(`:80`)は、無効にする**(MAAS の Rack は、`:5248` の専用設定を使う)。
  - **`systemd-timesyncd` → `chrony` の置き換えは、避けられない**(パッケージの依存)。control-plane の時刻同期の方式が変わるので、導入後に、時刻のずれと etcd の状態を確認する。
  - avahi-daemon は、mask を検討する。
- Rack 登録: `maas-rack register --url https://maas.kigawa.net/MAAS --secret <Bitwarden の値>`。secret は Bitwarden から取得(`bws_get_value`)し、ログに出さない。
- ノードの計画停止の前に、そのノードが DHCP の primary / secondary なら、割り当てを k8s1 などに付け替える手順を、運用手順に書く。**failover の設定の外で、DHCP を 3 台以上、同時に動かさない。**

### 3. バージョン(Region を先に 3.6 へ)
- `Dockerfile_region` の `MAAS_VERSION` を `3.6` にする(Ubuntu 22.04 の PPA に、3.6 があるかは、未確認)。
- Region を上げる前に、**PostgreSQL の `pg_dump` を取る**。migration は `migrate-job.yaml`(既存)。
- その後、Rack(3.6)をインストールする。

### 4. PostgreSQL
- Ceph RBD のまま。Ceph の fsync は遅い(10/4 の実測)が、MAAS の DB の書き込みは少ないので許容する。Ceph の障害で、MAAS が止まる可能性は受け入れる。
- **`pg_dump` の CronJob を足す**(出力先は Ceph とは別の場所)。restore 手順も書く。

### 5. BMC / 電源管理
- 試験機の BMC の方式は未確認。認証情報は、Bitwarden に置く。

### 6. #220 の扱い
- Rack を k8s に載せなくなったので、#220(k8s 上の MAAS の privileged / hostNetwork の隔離)の対象は、無くなる。**判断を記録して、close する(not planned)。**
- k8s の Region の `privileged` の理由(systemd と cgroup)を、docs に書く。

## 段階 0 の確認結果(2026-10-20、読み取りのみ)
- OS: k8s2 は Ubuntu 24.04.2、k8s4 は 24.04.3。
- **時刻同期:** 2 台とも `systemd-timesyncd` が active で、同期済み。`chrony` は inactive。**Rack の導入で `chrony` に置き換わる**(上記)。導入後に、同期の状態を確認する。
- **`:80`:** k8s2 は空き。**k8s4 は nginx(Ubuntu 標準の `default` サイトのみ、`conf.d` は空、`localhost:80` が 200)が動いている。** 独自の用途は無いので、Rack の導入時に `default` サイトを無効にして、`:80` を空ける(MAAS の Rack は、`:5248` を使う)。
- `bind9`・`avahi-daemon`:2 台とも inactive(入っていない)。
- **ファイアウォール:** k8s2 は `ufw` が active、**k8s4 は inactive**。k8s2 には、Rack のポート(67/69 udp、123 udp、5247 udp、5248/8000 tcp)と、failover のポート(647/7911 tcp)の許可が要る。k8s4 は、ufw が無効なので、ポートは開いている(iptables の INPUT の既定は、確認できなかった)。**k8s2 と k8s4 で、ufw の状態が違う点は、揃えるかを別途判断する。**
- failover のポート(647/7911)は、Rack が未導入なので、どちらも closed(想定どおり)。導入後に、k8s2 ↔ k8s4 の通信を確認する。

## 段階 1 の事前確認の結果(2026-10-20、読み取りのみ)
- **Region のバージョン:** `maas-region-api` / `maas-common` は 3.5.10(Ubuntu 22.04.5 のイメージ、`main-54b26e7a…`)。
- **MAAS 3.6 の PPA は、Ubuntu 22.04(jammy)用のリリースも無い**(使い捨ての 22.04 コンテナで確認。`jammy Release` が無い)。**Region のイメージのベースを、Ubuntu 24.04 に変える必要がある**(`Dockerfile_region` の `FROM ubuntu:22.04` と、systemd をコンテナ内で動かす部分を、24.04 で作り直す)。Region を 3.6 に上げる作業は、「`MAAS_VERSION` を変える」だけでは済まない。
- **DB の中身:** machine 0 件、rack / region ノード 44 件(Pod の再起動のたびに、別のホスト名で登録された古い登録とみられる)、subnet 5、ユーザー 3、DB サイズ 340MB、最新の migration は `maasserver` の `0330_bootresourcefile_filename_on_disk`。**machine が 0 件なので、DB に守るべき運用データはほぼ無い。** 万一の時は、DB を作り直しても、失うものは少ない(ユーザーと設定は、作り直しになる)。それでも `pg_dump` は、先に取る。
- **migration の仕組み:** `migrate-job.yaml` は、ArgoCD の **PreSync フック**で、sync のたびに実行される。Region のイメージを 3.6 に変えて sync すると、**DB の migration が、自動で、先に走る**(戻せない)。**`pg_dump` を、sync の前に取る**こと。なお、このジョブの image のタグ(`main-0d1ce1f…`)は、Region(`main-54b26e7a…`)と、違っている。揃っているか、確認が要る。
- **PostgreSQL:** worker1(I/O 飽和のノード、#240)に載っていて、再起動が 54 回(10/10 まで。liveness の `pg_isready` のタイムアウト 1 秒が、遅い Ceph で失敗するとみられる。10/10 19:45 以降は、安定)。段階 1 で DB を触る前に、liveness の設定(タイムアウト、失敗の閾値)を緩める。Ceph のままにする決定なので、配置も、worker1 を避ける。

## Region 3.6(Ubuntu 24.04)の試作の結果(2026-10-20、手元の Docker のみ。本番には触れていない)
- **`Dockerfile_region` の変更は、ほぼ「ベースを `ubuntu:24.04`、`MAAS_VERSION` を `3.6`」だけで、ビルドと systemd での起動が通る。** `entrypoint-region.sh` は、変更不要(`/etc/maas/regiond.conf` のキーも、3.5 と同じ)。インストールされたのは 3.6.6。
- **3.5 → 3.6 の DB の migration は、通る**(3.5.14 で作った DB を `pg_dump` → restore し、24.04 + 3.6.6 で `maas-region dbupgrade`、`maasserver` の 0323〜0340 の 14 件が適用されて exit 0。再実行は "No migrations to apply." で冪等)。本番の 3.5.10 から直接上がるかは、本番の DB では試していない。**PostgreSQL は 14 で検証した**(3.6 の対応バージョンは、未確認)。
- Region の `maas-apiserver`・`maas-http`・`maas-proxy`・`maas-regiond`・`maas-temporal`・`maas-temporal-worker` が active。`GET /MAAS/` は 301 → `/MAAS/r/`(200)。`/MAAS/api/2.0/version/` が 200 で `3.6.6`。**k8s の probe の `httpGet /MAAS/` は 301 を返す**(kubelet は、リダイレクトを追わず、2xx/3xx を成功とするので、通るはずだが、要確認)。
- **注意点:**
  - 起動直後に `maas-apiserver` が、証明書の準備前に落ちる(`TypeError … get_maas_cluster_cert_paths`)。自動再起動(10 秒後)で回復するので、初回は、エラーログが出る。startupProbe に余裕を持たせる。
  - **`maas-syslog`(rsyslogd)が、ホストの AppArmor のプロファイルで拒否されて失敗する**(`apparmor="DENIED" … profile="rsyslogd" name="/var/lib/maas/rsyslog.conf"`)。試作のホストで起きた。**k8s のノードで同じことが起きるかは、未確認**(ノードの AppArmor の状態による)。regiond 本体は動く。
  - 3.6 では、`maas-apiserver` と `maas-temporal` 系が、独立したサービスとして増えている(メモリが増える可能性)。
- k8s の `region.yaml` の cgroup の hostPath と、`--cgroupns=host` の要否は、試作では private で動いたので、検証していない。

## 未検証の点
- Region を 3.6 にして、既存の DB が migration できるか。Ubuntu 22.04 の PPA に 3.6 があるか。
- Rack の導入が、control-plane の既存サービス(kresd、HAProxy、時刻同期)に影響しないか。**実機に入れる前に、同じ OS の使い捨ての VM かコンテナで、サービスの起動を含めて確認する。**
- スイッチの DHCP の設定と、無効にする手順。試験機と BMC の有無。

## 段階
0. **読み取り:** スイッチの DHCP の設定を控える。k8s2 の `:80` と時刻同期の状態を確認する。試験機と BMC の有無。
1. **Region を 3.6 へ:** `pg_dump` → イメージの更新 → migration → Region の動作確認。
2. **Rack の導入(DHCP は無効のまま)。1 台ずつ:** module を作り、まず **k8s2**、次に **k8s4** に入れる。1 台ごとに、Region への登録、TFTP / HTTP の応答、kresd・時刻同期・etcd・kube-vip・BGP に異常が無いことを確認する。
3. **DHCP の切り替え(LAN に影響。時間帯を決める):** VLAN に primary(k8s2)と secondary(k8s4)を割り当て、failover の通信を確認する。その後、スイッチの DHCP を止め、MAAS の DHCP を有効にする。失敗したら戻す。**片方の Rack を止めて、もう片方が DHCP を継続することも確認する。**
4. **試験機 1 台:** PXE → enlist → commission → deploy。
5. **backup と運用手順:** `pg_dump` の CronJob、restore、Rack の付け替え、docs。

## 完了条件(#207 を、この設計に合わせて修正)
- Rack が k8s2 と k8s4 で稼働し、DHCP は primary / secondary の 2 台で冗長化され、片方を止めても、既存の端末にリースを配れる。
- Region と Rack が、同じバージョン(3.6)で動く。
- 試験機 1 台が Commission → Deploy まで通り、BMC の電源操作ができる。
- DB の backup と restore の手順がある。
- 隔離しない判断と、Rack の影響範囲が docs に記録されている。
