# openbao-backup

OpenBao の Raft スナップショットを定期的に取り、**age の公開鍵だけで暗号化**して、**Backblaze B2(Object Lock 付き、S3 互換 API)** に置く runner。設計は `docs/openbao-implementation-design.md` §7(バックアップ)と、§2「Raft の経路」。雛形は `modules/etcd-backup`。

- 実行ホスト: `hardware/ionos`(ionos-01)。WireGuard のハブで、EasyTier の overlay(`10.250.0.2`)を持つ。RAM の空きが少ないので、軽く作ってある(`MemoryMax=300M`、`Nice=10`、`IOSchedulingClass=idle`、一度に 1 プロセス)。
- `enabled = false`(既定)の間は、ホストに何も入れず、bws にも触れない。

## ファイル

| ファイル | 役割 |
|---|---|
| `files/openbao-backup.sh` | 本体(AppRole で取得 → 検証 → age で暗号化 → B2 へ PUT → メトリクス → 死活監視への ping) |
| `files/backup-policy.hcl` | バックアップ用 AppRole の policy(`sys/storage/raft/snapshot` の `read` のみ) |
| `main.tf` / `variables.tf` | ホストへの配置(systemd の service / timer、`/etc/hosts` の管理ブロック、`/etc/openbao-backup/`) |
| `test-openbao-backup.sh` | オフラインのテスト。偽の curl / age / date / logger を使い、実機にも OpenBao にも B2 にも触れない |

## 1. 世代(保持)の設計

実行のたびに、次の世代を書く。Object Lock の保持期間が、そのまま保持期間になる(削除は一切しない)。

| 世代 | キー(プレフィックス) | 書く条件 | 保持 |
|---|---|---|---|
| 6h | `6h/<UTC の時刻>.raft.snap.age` | 毎回 | 7 日 |
| daily | `daily/<YYYY-MM-DD>.raft.snap.age` | その UTC 日の最初の実行 | 30 日 |
| weekly | `weekly/<YYYY-Www>.raft.snap.age`(ISO 週、月曜始まり) | その週の最初の実行 | 84 日(12 週) |
| monthly | `monthly/<YYYY-MM>.raft.snap.age` | その月の最初の実行 | 365 日(12 か月) |
| adhoc | `adhoc/<reason>/<UTC の時刻>.raft.snap.age` | `--reason <text>` のときだけ | 30 日 |

- 「期間の最初の実行」は、**その期間の世代が B2 に無いこと**で判定する(`<key>.sha256` の HEAD)。そのため冪等で、同じ期間に 2 回走っても 2 つ目は daily / weekly / monthly を書かない。
- 月曜の実行が失敗しても、その週の次の実行(火曜など)が weekly を書く(取りこぼさない)。
- 各世代に、暗号化後のファイルの sha256 を入れた `<key>.sha256`(側ファイル)を置く。その側ファイルがある世代を「完了」とみなす。
- `--reason` のときは、adhoc だけを書く(6h は書かない)。例: OpenBao のアップグレード前に、`sudo /usr/local/bin/openbao-backup.sh --reason pre-upgrade`。理由は英数字で始まり、英数字と `._-` のみ(64 文字以内)。

## 2. 削除しない(保持は B2 に任せる)

- runner の B2 のアプリケーションキーには `deleteFiles` が無い。`bypassGovernance` も付けない。
- 保持は、(a) Object Lock の保持期間(上の表)と、(b) B2 の **Lifecycle ルール**(手動で設定。下の §4)で行う。
- Object Lock の期間内は、ロックされたファイルは消せない。Lifecycle ルールは、期間が過ぎたものだけを片付ける。

## 3. B2 のバケットと、書き込み専用のキー(手動)

1. **バケット**(B2 Cloud Console)
   - 名前: `openbao-backup`(`openbao_backup_b2_bucket` の既定値)。
   - **Object Lock を有効にして作る**(作成時に指定する。後から有効にできない前提で作ること)。
   - リージョンは、`b2_endpoint` と揃える(例: `us-west-004` → `https://s3.us-west-004.backblazeb2.com`)。
   - バケットの既定の保持(default retention)は**設定しない**。保持は、アップロードのたびに、スクリプトが付ける(世代ごと)。
2. **アプリケーションキー**(このバケットに限定)
   - 付与する権限: `listFiles`(任意。HEAD で 403 になるなら付ける)、`readFiles`、`writeFiles`、`writeFileRetentions`。
   - **付けない**: `deleteFiles`、`bypassGovernance`、`writeFileLegalHolds`、`listBuckets`、`writeBuckets` ほか。
   - 作成した keyID と applicationKey を、bws に登録する(§5)。

## 4. Lifecycle ルール(手動。B2 の「Lifecycle Settings」)

プレフィックスごとに、アップロードから「非表示(hide)」までの日数を、保持期間と同じにする。非表示から削除までは 1 日。Object Lock の期間内は、どのルールも消せないので、順序の誤りで早く消える心配はない。

| プレフィックス | daysFromUploadingToHiding | daysFromHidingToDeleting |
|---|---|---|
| `6h/` | 7 | 1 |
| `daily/` | 30 | 1 |
| `weekly/` | 84 | 1 |
| `monthly/` | 365 | 1 |
| `adhoc/` | 30 | 1 |

`.sha256` の側ファイルは、同じプレフィックスに入るので、同じルールに従う。

## 5. age の鍵(このバックアップ専用。etcd-backup と共有しない)

```bash
# オフラインの端末で(ホストで作らない)
age-keygen -o openbao-backup.agekey
# 出力の "# public key: age1..." の行が、公開鍵。openbao_backup_age_recipient に入れる
```

- **秘密鍵(`openbao-backup.agekey`)は、Bitwarden の安全なメモ(secure note)と、オフラインの控え(紙または暗号化した USB)の 2 系統で持つ。**
- **ホストに置かない。git に入れない。** ホストには公開鍵だけが入る(`AGE_RECIPIENT`)。ホストが侵害されても、過去のバックアップは読めない。
- 復号は、秘密鍵を持つ人間が、オフラインの端末で行う(§8)。

## 6. bws に登録する値

`hardware/ionos` の変数(§7)に、bws の ID を渡す。登録する値:

| 変数 | 中身 |
|---|---|
| `openbao_backup_b2_key_id_bitwarden_id` | B2 の keyID |
| `openbao_backup_b2_secret_bitwarden_id` | B2 の applicationKey |
| `openbao_backup_approle_role_id_bitwarden_id` | AppRole の role_id(§7 の手順で発行) |
| `openbao_backup_approle_secret_id_bitwarden_id` | AppRole の secret_id |
| `openbao_backup_healthcheck_url_bitwarden_id`(任意) | 死活監視の ping URL |

## 7. OpenBao の AppRole(1 回だけ。人間の管理者が、admin のトークンで行う)

```bash
bao auth enable approle

bao policy write openbao-backup hardware/modules/openbao-backup/files/backup-policy.hcl

# token は短命・使用回数を制限。secret_id は、ホストに置くため期限なし。
# 送信元は overlay の 10.250.0.2(ionos-01)に限る
bao write auth/approle/role/openbao-backup \
  token_policies="openbao-backup" \
  token_ttl=10m token_max_ttl=15m token_num_uses=10 \
  secret_id_ttl=0 secret_id_num_uses=0 \
  token_bound_cidrs=10.250.0.2/32 \
  secret_id_bound_cidrs=10.250.0.2/32

bao read  auth/approle/role/openbao-backup/role-id          # → role_id(bws へ)
bao write -f auth/approle/role/openbao-backup/secret-id     # → secret_id(bws へ。表示は一度だけ)
```

- `token_num_uses=10`: 1 回の実行で使うのは、snapshot の取得(失敗したエンドポイントの分も含む)と revoke だけ。
- ホストには `/etc/openbao-backup/role_id` と `/etc/openbao-backup/secret_id`(root のみ、0600)として配置される。
- 漏えいが疑われるときは、`bao write auth/approle/role/openbao-backup/secret-id-accessor/destroy secret_id_accessor=<...>` で secret_id を無効化し、§5 と同様に再発行する。

## 8. 復旧(手順の概要。詳細は `docs/openbao-restore.md` の Phase 3 で作る)

1. 対象の世代を選ぶ(B2 のコンソール、または読み取り専用のキーで取得)。
2. 側ファイル `<key>.sha256` と、取得したファイルの sha256 を比べる。一致しなければ、使わない。
3. **秘密鍵を持つ人間が、オフラインの端末で**復号する:
   `age -d -i openbao-backup.agekey -o raft.snap <取得したファイル>.raft.snap.age`
4. 復元する。**通常の復旧では `-force` を使わない**(`-force` は、Raft の構成が一致しないときの最終手段)。
   `bao operator raft snapshot restore raft.snap`(管理者のトークン。バックアップ用の policy は復元の権限を持たない)
5. Unseal と、Auth / Policy / 監査デバイスの確認を行い、結果を演習記録に残す。
6. 復元した snapshot は、作業が終わったら削除する(平文)。

## 9. 監視

textfile(`/var/lib/node_exporter/textfile/openbao_backup.prom`)に、次が出る:

- `openbao_backup_last_run_success`(1/0)
- `openbao_backup_last_run_timestamp_seconds`、`openbao_backup_last_success_timestamp_seconds`(失敗のときは前回の成功を引き継ぐ)
- `openbao_backup_tier_last_success_timestamp_seconds{tier="6h|daily|weekly|monthly|adhoc"}`
- `openbao_backup_size_bytes`、`openbao_backup_duration_seconds`

アラートの例: `openbao_backup_last_run_success == 0`、または `time() - openbao_backup_last_success_timestamp_seconds > 7 * 3600`。

**外部の死活監視(dead-man's switch)**: `openbao_backup_healthcheck_url_bitwarden_id` を設定すると、成功のたびに URL を、失敗のたびに `<URL>/fail` を呼ぶ。実行ホストが死んで何も送られなくなったときも、外部のサービスが通知する。期間は 6 時間 + 猶予 1 時間で設定する。

## 10. 有効化の手順

1. §3〜§7 を終える。B2 のバケットと、age の公開鍵、bws の値。
2. 最初は `openbao_backup_object_lock_mode = "GOVERNANCE"`(既定)。誤りのときに、管理者が戻せる。運用が固まったら `COMPLIANCE` に変える(変更は、新しく書く世代からの適用)。
3. `hardware/run.sh ionos plan` で、`openbao_backup_enabled = true` を指定して差分を確認する(§7 の変数と、bws の ID を渡す)。
4. apply のあと、ホストで `systemctl start openbao-backup.service` を一度実行し、`journalctl -u openbao-backup.service` と、B2 のコンソールで 6h / daily / weekly / monthly の 4 つのオブジェクトと側ファイルができたことを確かめる。
5. `openbao_backup_size_bytes` と、`openbao_backup_last_run_success 1` を、Prometheus で確かめる。

## 11. 未実装(別の作業)

- **月次の自動復元テスト**は、**まだ実装していない**。設計 §7 の「復旧演習」では、最新の世代を取得し、使い捨ての 1 ノードの OpenBao に復元して、canary を読む、という流れを想定している。復号の鍵は演習の時だけ人間が持ち込み、自動化ホストには置かない。別の issue で扱う。
- 別経路(実行ホスト以外)からの sha256 の検証。現状は、アップロード後の HEAD によるサイズ確認と、側ファイルの sha256 まで。

## 12. 前提と、未確認の事項

テストは、B2 の S3 API の挙動を、次の前提で書いてある。**実際の B2 で、最初の実行の前に確かめること**:

- SigV4 の署名は、`aws:amz:<region>:s3`(region はエンドポイントのホスト名から導く。例: `us-west-004`)。
- 追加のパッケージは使わない(`curl --aws-sigv4`)。curl が、利用者の指定した `x-amz-content-sha256` を、署名のペイロードのハッシュとして使うこと(未確認。実機の curl で署名の結果を確かめること。動かない場合は、ペイロードのハッシュの扱いを変える対応が要る)。
- PUT には `x-amz-object-lock-mode`、`x-amz-object-lock-retain-until-date`(`YYYY-MM-DDTHH:MM:SSZ`)、`x-amz-content-sha256`、`Content-MD5` を付ける。
- HEAD(`curl -I`)は、存在すれば 200 と `Content-Length`、無ければ 404。B2 の HEAD には `readFiles` が要る。403 になるなら、`listFiles` を足す。
- 平文のスナップショットは、`/run/openbao-backup`(tmpfs)にだけ置く。ホストに**スワップがあると、RAM 上の内容がスワップに出る可能性がある**(ionos-01 のスワップの有無は未確認。確認して、無ければ問題ない。あれば、暗号化されたスワップ、またはスワップを無効にすることを検討する)。
- スナップショットは gzip の tar で、`meta.json` と `state.bin` を含む(検証でこれを見る)。OpenBao のバージョンで形式が変わったら、`validate_snapshot` を直す。
- 取得は、`/v1/sys/storage/raft/snapshot` を GET する。どのノードが応答するか(アクティブかスタンバイか)は、実機で確かめる。成功しないエンドポイントは、次に回す。
- `age` は apt で入れる(`etcd-backup` と同じ)。`openssl` は、Content-MD5 の計算に使う。
- `/etc/hosts` の管理ブロックは、`bao-02.kigawa.net`(`10.250.0.1`)と、`bao-03.kigawa.net`(`10.250.0.31`)を指す。bao-02 側の ufw は、overlay(tun0)から 8200 を許可している前提(`modules/host-hardening`)。
