# MAAS の DHCP への切り替えの手順書(案)

kigawa-net/infra#207、[docs/maas-design.md](maas-design.md)(案 Q)。**この手順書は、案です。実行する前に、下の「未決・要確認」を、すべて、埋める。** MAAS の DHCP の設定と failover の動作は、**手元の Docker で検証済み**(下の「検証済みの手順と挙動」)。

**スイッチ(`192.168.1.1`)の DHCP を止め、MAAS の DHCP(k8s2 が primary、k8s4 が secondary)に、LAN 全体の DHCP を移す。** 失敗すると、LAN の全端末が IP を取れなくなる。慎重に、段階を分けて、進める。

## 現状(2026-10-22 時点。読み取りで確認したもの)
- Rack は、k8s2 と k8s4 の 2 台が、Region に登録済み(DHCP は、無効)。ファイアウォールは、DHCP(udp 67)と failover(tcp 647 / 7911、2 台の Rack の間だけ)を、許可する(この手順書と同じ PR 群)。時刻同期は、`chrony`。
- MAAS に、`192.168.1.0/24`(gateway `192.168.1.1`、managed)が、すでに登録されている。k8s2 の `enp0s31f6` と k8s4 の `ens18` が、**同じ VLAN** に紐づく。**どの VLAN も、`dhcp_on = false`。動的な IP の範囲(dynamic range)と、DNS の設定は、無い。**
- スイッチは `AT-x510-28GTX`(AlliedWare Plus 系)。**LAN の一般クライアントは、DHCP で配られる DNS として、スイッチ自身(`192.168.1.1`)を使う**(スイッチが `ip dns forwarding` で、各ノードの kresd(`192.168.1.103` / `.20` / `.120`)に中継。`docs/network.md`)。**MAAS が DHCP を担うときも、配る DNS は `192.168.1.1` にする**(kresd を直接配るのではなく、今と同じにする)。
- MAAS には、`kube-ipvs0` などのアドレスが、`/32` のサブネットとして、216 個、登録されている(Rack が、全インターフェースを報告するため)。DHCP は、VLAN ごとに有効にするので、動作には影響しない。画面と DB が、散らかる。

## 未決・要確認(埋めてから、実行する)
1. **スイッチの DHCP の全設定の控え**(あなたの操作が要る): プールの範囲、ゲートウェイ、DNS、リース時間、**固定の予約(MAC と IP)**、オプション。AlliedWare Plus の例(機種で、確認すること): `show running-config dhcp`、`show ip dhcp pool`、`show ip dhcp binding`。控えは、スイッチの外(手元)に、保存する。
2. **スイッチの DHCP を使っている端末の洗い出し。** 固定の予約がある端末(サーバー、プリンタ、IoT など)は、MAAS に、**予約(reserved IP。MAC つき)**として、作る。**抜けると、その端末の IP が変わる。**
3. **試験機と BMC の有無。** PXE で起動する物理マシン 1 台と、BMC の方式(IPMI / Redfish など)。BIOS か UEFI か。
4. ~~MAAS の DHCP の failover の動作確認~~ → **手元の Docker で、確認済み**(下の「検証済みの手順と挙動」。2026-10-22)。PXE の実機の起動(BIOS / UEFI)と DHCPv6 は、未確認。
5. **MAAS の設定の入れ方。** 検証は、公式の `maas` CLI で行った(管理者の API キーが要る。下の手順)。**本番の管理者と API キーを、どう用意するか、決める**(`maas-region createadmin` / `apikey` を、Region の Pod で実行すると、秘密が出る。扱いに注意)。
6. **実施の時間帯と、立ち会い。** LAN の利用が少ない時間。スイッチに、コンソールまたは SSH で、すぐ入れること。**切り替えの間、あなたがスイッチを操作できること。**

## 検証済みの手順と挙動(手元の Docker。2026-10-22)

Region(MAAS 3.6.6)+ PostgreSQL + Rack 2 台(primary / secondary)+ クライアントを、使い捨ての network(172.40.0.0/24)に作った。本番と同じ、Rack の導入のスクリプトと、ファイアウォール(`maas-rack-firewall.sh`)を使った。**実機のスイッチ・k8s2・k8s4 には、触れていない。**

### MAAS の設定のコマンド(すべて、実行して、成功を確認)
`<p>` は、`maas login <p> http://<Region>/MAAS <API キー>` のプロファイル名。サブネットは、Rack が報告した interface から、自動で現れる(本番の `192.168.1.0/24` は、すでに現れている)。
```
# サブネット: ゲートウェイ、DNS、allow_dns=false(必須。上の注)
maas <p> subnet update <subnet_id> gateway_ip=192.168.1.1 dns_servers=192.168.1.1 allow_dns=false
# 動的な IP の範囲(スイッチのプールと同じ範囲)
maas <p> ipranges create type=dynamic start_ip=<開始> end_ip=<終了> subnet=<subnet_id> comment="..."
# MAC ごとの予約(スイッチの固定の予約を、移す)
maas <p> reserved-ips create ip=<IP> subnet=<subnet_id> mac_address=<MAC> comment="..."
# DHCP の有効化(primary / secondary は、Rack の system_id。引数は fabric_id と vid)
maas <p> vlan update <fabric_id> <vid> dhcp_on=True primary_rack=<k8s2 の system_id> secondary_rack=<k8s4 の system_id>
# 無効化(戻し方)
maas <p> vlan update <fabric_id> <vid> dhcp_on=False
```
- **配られる設定は、`/var/lib/maas/dhcpd.conf` で確認する**(`domain-name-servers` が `192.168.1.1` だけであること、`routers`、`range`、`host` の予約、`failover peer`)。
- MAAS は、Region と Rack の IP も、`host` として、予約する。`option ntp-servers` は、2 台の Rack の IP(Rack の `chrony` が、LAN に時刻を配る)。
- リース時間は、既定で `600` 秒(`default` / `max`)。**「長めにする」の設定方法は、未確認**(DHCP snippet など)。
- `maas-dhcpd` は、`disabled` のまま(`systemctl enable` されない)。**起動は、`rackd` が行う**(再起動の後も、`rackd` が起動した)。導入のスクリプトの `disable --now maas-dhcpd` は、そのままでよい。

### 生成される `dhcpd.conf`(要点)
- `failover peer "failover-vlan-<id>" { primary; … mclt 3600; split 255; load balance max seconds 3; max-response-delay 60; max-unacked-updates 10; }`(secondary は `secondary;`。`mclt` と `split` は無い)。ポートは既定の 647。`omapi-port 7911`。
- PXE: `next-server` と `filename` は、**応答した Rack 自身の IP** を指す。アーキテクチャで分岐: BIOS は `lpxelinux.0`(`path-prefix http://<Rack>:5248/`)、UEFI(x64)は `bootx64.efi`(TFTP)または `http://<Rack>:5248/images/bootx64.efi`(HTTP)、iPXE は `http://<Rack>:5248/ipxe.cfg`、arm64 は `bootaa64.efi`。**両 Rack の udp 69 と tcp 5248 に、LAN から届く必要がある**(ファイアウォールで許可済み)。

### 挙動(時間つき)
- **有効化から、2 台とも `normal` になるまで、約 2 秒。**
- クライアントのリース(DISCOVER → OFFER → REQUEST → ACK)は、約 0.4〜1.4 秒。予約の MAC は、予約の IP を得る。応答する Rack は、正常時、両方が混ざる(`split 255` + load balance)。
- **正常な時、`load balance max seconds 3` により、DISCOVER の一部が、約 3 秒遅れて応答される**(ISC の仕様)。切り替えの直後に、一時的に遅く見えても、異常ではない。
- **片方の Rack が落ちたとき(primary でも secondary でも、同じ):** 生き残った Rack が、`communications-interrupted` になり、**既存のリースの更新(約 0.5〜0.7 秒)も、新規のリース(数分後でも)も、継続して応答する。** 落ちた Rack が戻ると、約 4 秒で `normal` に戻り、両方のリースの DB が一致する。
- **`partner-down` には、自動では、ならない**(5 分以上、`communications-interrupted` のまま)。**長期の片側の停止では、運用者が判断する**(MAAS からの `partner-down` の設定方法は、未確認)。
- **2 台の間の接続(tcp 647 / 7911)だけが切れ、両方が生きているとき:** 約 56 秒で、お互いに `communications-interrupted` になり、**両方が応答する**(異なる IP を出した。3 件の試験では、重複は無し)。接続が戻ると、約 12 秒で `normal`。**長時間の分断での、IP の衝突の有無は、未確認。**
- `dhcp_on=False` で、両 Rack の `maas-dhcpd` が止まり、応答が止まる(戻し方として、有効)。再び `True` で、約 30 秒で戻る。
- **ファイアウォール:** 本番と同じ `maas-rack-firewall.sh`(udp 67 と、相手の Rack だけの tcp 647 / 7911)を入れた状態でも、DHCP と failover が動く。足りない許可は、なかった。**`DHCP_PEER_ADDRESS` は、両方の Rack で必要**(片方だけだと、既存の接続は保たれるが、再接続のときに止まる。両側から外すと、約 15 秒で `communications-interrupted`)。

### 監視(切り替えの後)
- 両 Rack の `journalctl -u maas-dhcpd` に、failover の状態(`normal` / `communications-interrupted`)が、出る。`communications-interrupted` が続いたら、相手の Rack を確認する。
- 端末が、MAAS から、IP・ゲートウェイ・**DNS(`192.168.1.1` だけ)**を受け取ること。

## 事前準備(LAN に影響しない)
1. 上の 1・2・3 を、埋める。スイッチの設定の控えを、保存する。
2. (任意)スイッチのリース時間を、事前に、短くする(例: 数時間)。切り替え後に、端末が、早く、MAAS のリースに移る。**ただし、これは、スイッチの設定の変更で、LAN に影響する。** 必要性を、判断する。
3. **MAAS 側の準備**(DHCP は、まだ、有効にしない):
   - `192.168.1.0/24` の VLAN で、**動的な IP の範囲(dynamic range)**を作る。**スイッチのプールと、同じ範囲**にする(切り替え前に、スイッチのプールと、重ならないように、注意する。重なる範囲が、同時に、2 つの DHCP から配られると、IP が重複する)。
   - **ゲートウェイ**: `192.168.1.1`(登録済み)。**DNS**: `192.168.1.1`(スイッチと同じ)。**`allow_dns=false` が必須**(既定の `true` のままだと、MAAS は、DHCP で配る DNS の先頭に、Rack 自身の IP(k8s2 / k8s4 の LAN のアドレス)を、入れる。`dns_servers=192.168.1.1` だけでは、足りない)。
   - **予約**: スイッチの固定の予約を、MAAS の reserved IP(MAC つき)として、作る。
   - **リース時間**: 長めにする(Rack が止まったときの余裕)。
4. 事前の確認: `maas-rack-firewall.service` が、k8s2 と k8s4 で、DHCP と failover を許可していること(`iptables -S MAAS-RACK`)、2 台の Rack が、Region に接続していること、時刻同期、`pg_dump` の取得、**スイッチの設定の控えが、手元にあること**。
5. **戻し方を、先に、練習する**(下の「戻し方」)。

## 切り替え(LAN に影響する。時間帯を決める)
**同時に、2 つの DHCP が、同じ範囲を配らない**ように、短い間隔で、入れ替える。
1. 事前確認(上の 4)を、もう一度。
2. MAAS で、VLAN の **DHCP を有効**にする(primary: k8s2、secondary: k8s4)。`dhcpd` が、2 台で、起動し、failover が確立するのを、待つ(`maas-dhcpd` が active、failover の状態が、normal)。**この時点では、スイッチの DHCP も、まだ動いている。** 2 つの DHCP が、同じ範囲を配る、短い期間になるので、**範囲を、スイッチと、一時的に、ずらす**(MAAS の範囲を、スイッチのプールの未使用部分にする)か、間隔を、できるだけ、短くする。
3. **スイッチの DHCP を止める**(`no service dhcp-server`、またはプールを無効にする。AlliedWare Plus のコマンドは、機種で確認)。
4. 確認: 
   - 端末で、リースを更新して(`dhclient -r` / ネットワークの再接続)、**MAAS の DHCP から、IP・ゲートウェイ・DNS を、受け取る**こと。
   - MAAS の UI / API で、リースが見えること。k8s2 と k8s4 の `dhcpd` の failover が、normal であること。
   - 固定の予約の端末が、同じ IP を、受け取ること。
   - **配られた DNS が、`192.168.1.1` だけ**であること(`allow_dns=false`。Rack の IP が、入っていないこと)。
   - 試験機が、PXE で、起動する(TFTP、`lpxelinux.0` / `grubx64.efi`)こと。
5. **片方の Rack を止めて(`systemctl stop maas-rackd` など)、もう片方が、リースを、継続する**こと。戻す。
6. 監視: 数時間、端末の IP の取得の失敗が、無いこと。

## 戻し方(いつでも、最優先)
1. **スイッチの DHCP を、有効に戻す**(控えの設定)。
2. MAAS で、VLAN の **DHCP を無効**にする(`dhcpd` が、止まる)。
3. 端末が、リースを、更新するのを、待つ(または、再接続)。
- スイッチの設定の控え(1)が、手元に無いと、戻せない。**切り替えの前に、必ず、保存する。**

## 切り替えの後
- `kigawa-net/infra#207` を更新する。docs(`maas-design.md`、`network.md`)を、実際の運用に合わせる。
- スイッチの、`ip name-server` と `ip dns forwarding` は、そのまま(DHCP とは別の機能)。
- `/32` のサブネットの散らかりの対処(Rack が報告する interface の除外)は、別に、検討する。

## 未確認(実機でしか、確認できないこと)
- **PXE の実機の起動**(TFTP / HTTP のファイル取得、BIOS と UEFI の違い)。手元の検証は、`dhcpd.conf` の内容までで、実機のブートは、していない。`maas-agent`(ブートイメージのキャッシュ `httpproxy`)は、本番で、正常に動き出した(`/var/cache/maas/httpproxy` が作られた)が、イメージの配布は、未確認。
- DHCPv6。
- 長時間の分断での IP の衝突。`partner-down` の設定方法。
- リース時間を長くする設定方法。
- **本番の `maas-syslog`**: Region のノード(worker4)では、ホストの AppArmor で失敗した。k8s2 と k8s4 の Rack では、動いている(`active`)ことを確認した(DHCP とは無関係)。
- スイッチの設定の控えを元にした、動的な範囲と予約の、実際の値(あなたの控え)。
