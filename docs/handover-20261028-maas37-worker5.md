# 引継書: MAAS 3.7 化と k8s-worker5 の再構築(2026-10-24〜28)

作成: 2026-10-28 00:10 JST(Claude Code のセッションで実施した作業の引継ぎ)。関連 Issue: kigawa-net/infra#316(worker5 の再構築)、#317(MAAS の 3.7 化)、#207(MAAS の再設計)。

## 1. 一言で
- **MAAS(Region・Rack)を 3.6 から 3.7.4 に上げ、OS イメージの取り込みを直し、k8s-worker5 を MAAS で再構築した**(OS を新しい SSD に入れ直し、クラスタに復帰)。
- 途中で、**DHCP の停止 → worker1 のネットワーク断 → Ceph の劣化**という連鎖障害が起きたが、復旧済み。
- **残り: Ceph の回復の完了(劣化 6.9% → 0)と、osd.7 の purge、`noout` の解除。** 詳細は「5. 未完了」。

## 2. 現在の状態(2026-10-28 00:10 JST の実測)
| 項目 | 状態 |
|---|---|
| ノード | 7 台すべて `Ready`(k8s1 / k8s2 / k8s4 / k8s-worker1 / 3 / 4 / 5) |
| Ceph | OSD 12 台中 11 台 up、osd.7 は `out`(down)。劣化 6.9%(68 PG)、151 PG が remapped(**回復中**)。inactive な PG なし。mon 3/3。`noout` 設定中。警告: `mon fr` の空き容量、`nearfull osd` 1 台、deep-scrub の遅れ |
| OSD の使用率 | 最大 86%(osd.6)。新しい osd.11(2TB の SSD)は、バックフィルで増加中 |
| MAAS | Region・Rack(k8s2 / k8s4)とも 3.7.4。DHCP 復旧(failover `Both servers normal`)。WoL の webhook 稼働 |
| worker5 | MAAS で `Deployed`(Ubuntu 24.04.5、192.168.1.150 固定、ユーザー kigawa)。クラスタに参加済み(`Ready`) |
| worker5 の OSD | osd.1(Toshiba 2TB)・osd.3(WDC 4TB)は復帰。**osd.11 は、新しい 2TB の SSD(Crucial CT2000BX500、シリアル 2535E9C9B227)から、Rook が作った新規 OSD** |
| osd.7(元の 1TB の SSD、CT1000BX500、シリアル 2135E5CB2CD6) | **所在不明**(ディスクが見えない)。`out` にして、再複製中。purge の予定 |

## 3. 実施した変更(PR)
**kigawa-net/infra**
| PR | 内容 |
|---|---|
| #318 | Rack を 3.7 に上げる仕組み(`maas-rack-upgrade.sh`、`maas_version` 必須、ホストごとの `maas_rack_version`)。再 apply で稼働中の `maas-dhcpd` を止めないよう、`maas-rack-install.sh` を修正 |
| #319 | **3.7.4 の Rack だけの構成で rackd が起動しない不具合の回避**(`maas-rack-shim.sh`) |
| #321 | k8s2 の Rack も 3.7 に |
| #322 / #324 | k8s-worker1 の固定アドレス・デフォルト経路(`modules/static-network`)、cluster-route |
| #329 / #330 / #331 | **MAAS 用の Wake on LAN の webhook**(各 Rack の 127.0.0.1:5290)。URL は `localhost`。`/wake` の後 300 秒は `running` を返す |
| (閉じた)#334 | `cluster-info` を使わない join(`--discovery-file`)。**kubeadm 1.30 は、この方式でも `cluster-info` を取るため、使えなかった**。閉じた |

**kigawa-net/kigawa-net-k8s**
| PR | 内容 |
|---|---|
| #428 | Region のイメージを MAAS 3.7 に(`Dockerfile_region`) |
| #430 | `region.yaml` と `migrate-job.yaml` のイメージのタグを 3.7 にそろえる(`maas-build` の自動更新が `GIT_TOKEN` の失効で失敗したため、手で更新) |
| #435 | Region の LB(VIP 10.0.0.244)に、内部 API の **tcp 5242** を追加(3.7 の maas-agent が DHCP の設定を取るのに必要) |

## 4. 経緯(障害の連鎖。原因の理解に重要)
1. 目的: worker5 を MAAS で再構築する。MAAS が、OS イメージの取り込みで、毎回失敗した。
2. **取り込み失敗の原因は、複数が重なっていた**: (a) Region のディスクの空き不足の判定(32.9GB 必要。取り込み対象を noble の ga / hwe に絞って解消)、(b) DB(Ceph の HDD を含む RBD)の同期書き込みが 260〜570ms で、Temporal がタイムアウト(構成の限界)、(c) **古い Region コントローラーの記録**(Pod を作り直すたびに増える。`region:<id>` のタスクキューに、誰もいない)で、削除のワークフローが毎回失敗(`region-controller delete <system_id>` で解消)、(d) 3.6 の Rack は 3.7 の Region のタスクを処理できない、(e) MAAS 3.6.x の既知の不具合 LP#2121474。
3. Region を 3.7.4 に上げた(2026-10-24 23:05 JST)時刻に、**k8s2 の maas-dhcpd が停止**(3.6 の Rack が、3.7 の Region から DHCP の設定を適用できない)。
4. **worker1 は、DHCP のリース(24h)で 192.168.1.228 とデフォルト経路を得ていた**ため、10/25 12:18 JST にリース切れで NotReady → Ceph の OSD 4 台と mon が down → **Rook が osd.9 の Deployment を自動削除**(`removeOSDsIfOutAndSafeToRemove: true`)。「固定 IP だから DHCP は不要」という前提は、worker1 には成り立たなかった。
5. 復旧: DHCP(Rack を 3.7 にそろえ、LB に 5242 を追加)、worker1(経路とアドレスを手動 → IaC)、osd.9(`ceph osd set noout` → `ceph osd in 9` → Rook の operator を再起動)。
6. worker5 の再構築: OSD を止め(1 コピーで運用)→ ディスクと USB の交換 → MAAS で commission / deploy → `terraform apply` で join。join は、**`kube-public/cluster-info` が存在せず**失敗し、一時的に作って join し、直後に削除した。

## 5. 未完了(優先順)
1. **Ceph の回復の完了**: 劣化と remapped が 0 になるまで待つ(数時間)。`ceph status` で確認。
2. **osd.7 の purge**: osd.7 は `out` にしてある。全 PG が clean になり、`ceph osd safe-to-destroy osd.7` が「安全」を返したら、次を実行する(**clean になる前に purge しない。データを失う**)。
   ```
   ceph osd purge 7 --yes-i-really-mean-it
   kubectl -n kigawa-system-rook-ceph delete deployment rook-ceph-osd-7
   ceph osd unset noout
   ```
   (セッション内のバックグラウンドのスクリプトが、同じことを自動で行う設定だが、**セッションが終わると止まる**。手動で確認すること。)
3. **`noout` の解除**(上の手順 2 の最後)。回復後も残すと、OSD が out にならず、障害時に再複製が始まらない。
4. **`kube-public/cluster-info` が無い件の判断**: 他のノードの再 join で同じ問題が起きる。**意図的な削除(セキュリティ事故の対応)だったか不明**。意図でなければ、`kubeadm init phase bootstrap-token` で再作成(恒久)。意図なら、join のたびに、一時的に作って削除する(手順は「6-E」)。
5. **MAAS の電源オフ**: WoL では電源を切れない。MAAS の UI の `Power off` は、機械が起動していると失敗する。webhook の `/off` で、SSH による shutdown に対応する PR が、必要(Rack に、シャットダウン専用の鍵と、sudo の限定ルール)。
6. **#316、#317 の Issue の更新と、クローズの判断**(取り込みの完了、worker5 の復帰は達成済み)。
7. ほかのノード(特に DHCP に依存するもの)の洗い出し: worker1 以外にも、DHCP のリースに依存する端末が、ないか(このセッションでは未確認)。

## 6. 手順書(再現に必要な知識)
### A. MAAS の API(Region の Pod の中で maas CLI を実行する)
- 管理者の API キーは、`~/dev/maas`(0600、1 行)。**キーは、引数や画面に出さず、標準入力で渡す**。
  ```
  kubectl -n kigawa-net-maas exec -i deploy/maas-region -c maas-region -- sh -c \
    'read -r KEY; maas login lab http://127.0.0.1:5240/MAAS "$KEY" >/dev/null 2>&1; maas lab <コマンド...>' < ~/dev/maas
  ```
- worker5 の system_id は `kt7w78`(`machine read kt7w78`)。
- Region の Pod を作り直したら、`region-controllers read` で古い記録(存在しない Pod のもの)を確認し、`region-controller delete <system_id>` で消す(消さないと、OS イメージの削除ワークフローが失敗する)。

### B. Terraform の apply(**手元の Terraform 1.13 で state を書くと、CI(1.6)が読めなくなる**)
- Terraform **1.6.6** のバイナリを取得し、PATH の先頭に置く。`TF_DATA_DIR` は、書き込める別の場所にする。
- `hardware/run.sh <module> plan|apply ...`。`BWS_ACCESS_TOKEN`(短命。`~/dev/bws`)が要る。
- **k8s2 / k8s4 は、`-target=module.maas_rack` に絞る**(`module.control_plane` に、9/25 の #170 以降の未適用の差分があり、稼働中の control-plane で、スクリプトを再実行しないため)。**ただし、CI の `Terraform` ワークフローは、マージのたびに、全体を `apply` する**(2026-10-26 から、CI で Bitwarden の認証が使える)。control_plane の差分が CI で適用されたかは、未確認。
- worker5 の再 join: `null_resource` は、state にあるため、再実行されない。`-replace` を付ける(または、tainted のものは、そのまま再作成される)。古い Node オブジェクトは、先に `kubectl delete node k8s-worker5` で消す。

### C. Bitwarden のレート制限
- identity が **429**(約 2 時間で解除)になる。`bws` を短時間に何度も呼ぶと起きる(plan / apply は、1 回に数回〜十数回呼ぶ)。
- 待つときは、`curl https://identity.bitwarden.com/.well-known/openid-configuration` を、10〜20 分おきに 1 回だけ確認する(200 になったら解除)。

### D. Wake on LAN と MAAS の電源(worker5)
- BMC の無い自作 PC。MAAS の電源の種類は `webhook`。**URL のホストは `localhost`**(`127.0.0.1` だと、`RackController matching query does not exist` で、UI が `Power error` になる)。
  - on: `http://localhost:5290/wake?mac=02:39:7a:2e:13:f0`、query: `http://localhost:5290/status?mac=...&ip=192.168.1.150`。
- **WoL が効くのは、NIC が WoL を待つ状態で停止したときだけ**。MAAS の一時環境(commissioning)で止めると、NIC が待たず、WoL が効かない(電源ボタンが必要)。deploy 済みの OS には、netplan で `wakeonlan: true` を入れてあるので、OS から正常に shutdown すれば、効く見込み。
- UI の `Power on` は、状態が `Broken` / `Deployed` / `Deploying` のときだけ押せる。`Ready` のマシンは `Commission` / `Deploy` が電源を入れる。`Failed testing` は `Override failed testing` で `Ready` にする。
- 手動のマジックパケット: 同じ LAN から UDP 9 / 7 に、ブロードキャスト。

### E. worker5 の再 deploy(OS の入れ直し)
1. 先に `ceph osd set noout` → `cordon` → `drain`(OSD の Pod は、PDB で退避されないので、`kubectl scale deploy rook-ceph-osd-<ID> --replicas=0`)。
2. 停止 → OSD の SATA ケーブルを外す(インストーラが消さないよう)→ **USB メモリは抜く**(Rook の `deviceFilter: sd.` が、空のディスクを OSD にするため)→ MAAS で commission → deploy(storage layout は flat)。
3. `terraform apply` で join。join には `kube-public/cluster-info` が必要(5-4 を参照)。一時的に作る場合は、CA と API サーバーの URL だけの ConfigMap を作り、join の直後に削除する。
4. OSD のケーブルを戻して起動 → osd の Deployment を `replicas=1` に戻し、Rook の operator を再起動して再検出させる。

### F. DHCP
- MAAS の DHCP(k8s2 が primary、k8s4 が secondary)。**ホストが MAC で予約**(worker1 の .228 など)。リースは、予約 86400 秒、動的 3600 秒(MAAS の `mclt`)。スイッチの `pool manage` は、止めてある(`pool ceph` は、MAAS の対象外で、残す)。
- DHCP の設定を再適用したいときは、`vlan update 3 0 dhcp_on=False` → `dhcp_on=True primary_rack=<k8s2> secondary_rack=<k8s4>`。

## 7. 落とし穴(やってはいけないこと)
- **ホストを止める作業の前に、必ず `ceph osd set noout`。** Rook は、`out` で safe-to-destroy な OSD の Deployment を自動で消す(`removeOSDsIfOutAndSafeToRemove: true`)。
- Ceph が clean でない間に、OSD を purge しない。
- k8s のノードを、DHCP に依存させない(固定にする)。
- MAAS の Region の Pod を作り直したら、古い Region コントローラーを消す。
- `maas-build` の `GIT_TOKEN` は失効している。イメージのタグは、手で更新が必要(CI が自動で `region.yaml` を更新できない)。
- `cluster-info` を、承認なしに作らない(共有クラスタの変更)。
- Terraform の state を、手元の 1.13 で書かない。

## 8. 秘密情報・セキュリティ
- `~/dev/maas`(MAAS の管理者 API キー)と `~/dev/bws`(Bitwarden の短命トークン)が、平文のファイルとして、手元にある(0600)。**不要になったら、削除する。MAAS の API キーは、ローテーションを推奨**。
- 作業中に、**スイッチの管理者のパスワード(平文)が、会話に出た**(変更をお願い済み。変更の確認は、未)。
- worker5 の `kigawa` ユーザーの sudo パスワードは、Bitwarden のものと同じ(cloud-init には、ハッシュだけを入れた)。MAAS の DB に、そのハッシュが残る。
- MAAS の DB のバックアップ: `~/backups/maas/maas-20261024-223853.dump`(3.6 → 3.7 の `dbupgrade` の直前。restore の件数は、本番と一致を確認済み)。

## 9. その他の気付き(未対応)
- k8s の `kigawa-net-k8s` の手元の checkout(`/home/kigawa/dev/kigawa-net/kigawa-net-k8s`)は、main より 281 コミット遅れで、ステージ済みの削除がある(このセッションでは、触っていない)。
- 無関係な異常な Pod(`ktcl-*` のイメージが見つからない、`gijiroku-bot` の CrashLoop、`mcp-for-argocd` の Secret に `token` キーなし、など。Bitwarden のトークン失効の影響の可能性)。
- Region(MAAS)の PVC(イメージの保存先)が無く、Pod を作り直すと、OS イメージが失われる。
- `named`(MAAS の DNS)が、大量のログを出している(原因は未調査)。
- worker4 のルートの使用率が 70% で、`mon fr` の空き容量の警告が出ている。

## 10. 参照
- Claude Code のメモリ: `project_maas37_upgrade_20261025.md`、`project_worker5_rebuild_20261024.md`(MAAS の詳細な経緯と、今回の学び)。
- Issue: kigawa-net/infra#207(MAAS の再設計)、#316、#317。
- ドキュメント: `docs/maas-design.md`、`docs/maas-dhcp-cutover.md`、`hardware/modules/maas-rack/README.md`。
