# openbao-node

OpenBao のノード(raft の voter 1 台)を、SSH provisioner で構築する module。設計は `docs/openbao-implementation-design.md` §2、issue kigawa-net/infra#327 の Phase 1。

呼び出し元: `hardware/bao-02/`(`enabled = false` の間は、何も作らず Bitwarden にも触れない)。

## 構成

| ファイル | 役割 |
|---|---|
| `main.tf` | `null_resource`。設定・unit・証明書を stage に置き、setup script を sudo 経由で bash 実行する |
| `variables.tf` | 入力。Cloudflare の API トークンと sudo パスワードは `sensitive` |
| `files/openbao.hcl.tpl` | `/etc/openbao/openbao.hcl` の描画元(`templatefile`) |
| `files/openbao-node-setup.sh` | 構築・更新の本体(冪等) |
| `test-openbao-node.sh` | オフラインのテスト(設定の描画、setup script の挙動) |

## 何をするか

1. 公式の `.deb` を、**固定バージョン**で取得し、**SHA256 を検証**してから、`dpkg-deb -x` で `bao` を取り出す(`apt` は使わない)。
2. 専用ユーザー `openbao`(system、ログイン不可)、`/var/lib/openbao`(0700、ローカルの ext4 を想定)、`/etc/openbao`。
3. **TLS の証明書は、ノード自身が certbot で発行・更新する**(Let's Encrypt、DNS-01 / Cloudflare)。詳細は下の「TLS」を参照。秘密鍵は Terraform を通らない。
4. `/etc/hosts` に、自分と他ノードの fqdn を WireGuard の IP で載せる(管理ブロック。内容が同じなら書き換えない)。
5. `openbao.hcl`(raft、retry_join は FQDN、listener 8200/8201 を WireGuard IP と loopback のみ、`tls_min_version = "tls13"`、telemetry の認証必須、ui 無効)と `openbao.service` を置く。
6. `systemctl enable --now`。設定・unit が変わったら再起動。**証明書の更新は deploy hook が `systemctl reload`(SIGHUP)で反映する**。OpenBao は、証明書が配置されてから起動する。

## TLS(Let's Encrypt、DNS-01)

- **名前**: `fqdn`(例: `bao-02.kigawa.net`)。`api_addr` と `retry_join` の宛先はこの名前を使う。公開 DNS には A レコードを置かず、`/etc/hosts` で WireGuard の IP に向ける。
- **発行**: `certbot certonly --dns-cloudflare -d <fqdn>`。証明書が無いときだけ発行する。`certbot.timer` が更新する。更新後の deploy hook(`/etc/letsencrypt/renewal-hooks/deploy/openbao-tls.sh`)が `fullchain.pem` / `privkey.pem` を `/etc/openbao/tls/tls.crt` / `tls.key`(0600 openbao)へ写し、OpenBao が起動中なら SIGHUP で再読込する。
- **Cloudflare のトークン**(`cloudflare_api_token`): `kigawa.net` ゾーンの **Zone:DNS:Edit だけ**の権限にする。**Cloudflare 側で、クライアント IP の制限を bao ノードの公開 IP(bao-02 は 207.231.111.196)だけに設定すること**(トークンの「Client IP Address Filtering」)。レコード名では絞れないため、IP 制限が無いと、トークンが漏れたときに `kigawa.net` の DNS を書き換えられる。
- **トークンの扱い**: トークンは、ノードの `/etc/letsencrypt/cloudflare.ini`(0600 root)に置くために、Terraform の provisioner input として渡る。**そのため Terraform の state に入る**(既存の SSH 鍵と同じ扱い。state は R2 backend の方針どおりに暗号化・アクセス制御する)。トークンはコマンドラインに載せず、STAGE_DIR 経由で渡し、ログにも出さない。
- **staging**(`acme_staging = true`): Let's Encrypt の staging を使う。試験用で、ブラウザや OpenBao の検証では信頼されない。切り替えると、既存の証明書を消して発行し直す(本番の証明書が staging に置き換わらないようにするため、切り替えは明示的に行う)。
- **連絡先メール**(`acme_email`): 既定は空(`--register-unsafely-without-email`)。実在のアドレスは既定値に書かず、呼び出し側から渡す。
- **失敗時**: 発行済みの証明書と `cloudflare.ini` は戻さない(再発行はレート制限に当たるため)。発行に失敗したら、OpenBao は起動しない。

## 初期化・鍵について

### systemd unit の硬化

`User=openbao`、`NoNewPrivileges`、`ProtectSystem=strict`、`ProtectHome`、`PrivateTmp`、`PrivateDevices`、`MemoryDenyWriteExecute`、`LimitCORE=0`、`SystemCallFilter=@system-service`、`CapabilityBoundingSet=`(空。全て落とす)。データは `StateDirectory=openbao` で `/var/lib/openbao` だけに書ける。

### mlock と swap

**OpenBao 2.x は mlock をやめた**(2.7.2 で確認: 設定に `disable_mlock` があると、`OpenBao has dropped support for mlock` で起動に失敗する)。そのため、`disable_mlock` は書かず、`LimitMEMLOCK` と `CAP_IPC_LOCK` も持たせない。メモリを swap に出さない対策は、swap を無効にする(bao-02 / bao-03 は swap なし)か、暗号化する(https://openbao.org/docs/install/#post-installation-hardening)。

セットアップの script は、`systemctl start` の後に数秒待ち(`OPENBAO_START_WAIT`、既定 5)、`openbao` が動き続けているかを確認する。起動直後に設定エラーで落ちても、失敗として止まり、直近のログを出す。

## 初期化・鍵について

- **`bao operator init` は、この module も setup script も行わない。** 初期化は手動の別手順。
- Unseal 鍵・root token は、Terraform の state・ログ・Bitwarden のいずれにも保存しない。
- setup script は、`operator` を含むコマンドを一切実行しない(テストで確認している)。
- 失敗時の cleanup は、このランで足したもの(unit・設定ファイル)だけを戻す。**`/var/lib/openbao` は、`wipe_data_on_failure = true` のときだけ消す**(既定は `false`)。初期化後の誤削除を防ぐため。
- ステージ(秘密鍵を含む)は、成否にかかわらず終了時に消す。

## 変数

| 名前 | 既定 | 説明 |
|---|---|---|
| `host` | (必須) | SSH の接続先。WireGuard のアドレスではない |
| `ssh_user` | `kigawa` | |
| `ssh_private_key` / `sudo_password` | (必須) | `sensitive` |
| `node_id` | (必須) | raft の node_id。小文字・数字・ハイフン |
| `wg_address` | (必須) | WireGuard 上の IPv4(単独) |
| `fqdn` | (必須) | このノードの証明書の名前(例: `bao-02.kigawa.net`)。小文字の FQDN |
| `cloudflare_api_token` | (必須) | `sensitive`。DNS-01 用(英数字・`_`・`-` のみ)。上の「TLS」を参照 |
| `acme_email` | `""` | Let's Encrypt の連絡先。空なら `--register-unsafely-without-email` |
| `acme_staging` | `false` | `true` で Let's Encrypt の staging(試験用)。切り替えると発行し直す |
| `peers` | `[]` | 他のノード。`{fqdn, address}`(`address` は WireGuard の IPv4)。自分自身(`fqdn` が一致するもの)は無視される。`/etc/hosts` と `retry_join` に使う |
| `openbao_version` | (必須) | `X.Y.Z` 固定。`latest` は不可 |
| `openbao_deb_sha256` | `""` | 公式 `.deb` の SHA256。空のままでは apply できない(precondition) |
| `wipe_data_on_failure` | `false` | 失敗時に `/var/lib/openbao` を消すか |

TLS の秘密鍵・証明書は、この module の変数にならない(Terraform の state に入らない)。

`.deb` の URL は `https://github.com/openbao/openbao/releases/download/v<version>/openbao_<version>_linux_amd64.deb` を使う。

## ネットワーク・ファイアウォール(この module の対象外)

この repo には、ホストの FW を一括で管理する仕組みが無い(`k8s4` のように個別に iptables を書いているだけ)。そのため、この module では FW を設定しない。運用では、次の制限を別途入れること(全体設計 §2 の表どおり)。

- 8200(API): 認証済みクライアントの経路だけ。
- 8201(cluster): bao ノード同士の WireGuard アドレスだけ。
- 22(SSH): 管理網だけ。
- WireGuard の AllowedIPs は、bao 用の /32 だけを個別ピアに割り当てる(同一 AllowedIPs を複数ピアに割り当てない。issue #121)。

8200/8201 は WireGuard と loopback にだけ bind する(公開 IF には bind しない)ので、FW が無くても公開 IF からは届かない。

## テスト

```bash
bash hardware/modules/openbao-node/test-openbao-node.sh
```

- 設定の描画は、出力だけの一時的な Terraform root(provider 不要)で `templatefile` を評価する。`terraform` が必要。
- setup script は、`OPENBAO_ROOT` を一時ディレクトリにし、偽の `curl` / `systemctl` / `useradd` / `bao` で動かす。実機・Bitwarden・ネットワークには触れない。
- 確認内容: 描画(listener、tls13、api_addr の fqdn、retry_join の FQDN と自分の除外、`leader_ca_cert_file` が無いこと)、証明書は無いときだけ発行・有るときは発行しない、staging と本番の切り替え、apt の導入は初回だけ、`/etc/hosts` の管理ブロックの冪等性、deploy hook の内容と 0755、hook による配置(0600)と SIGHUP のみ、発行失敗時に起動しないこと、SHA256 不一致、起動失敗時の巻き戻し、`wipe_data_on_failure` の挙動、`operator init` が呼ばれないこと、トークンが出力・呼び出し記録に出ないこと。
- certbot・apt-get・dpkg・systemctl は偽物で置き換える。本物の Let's Encrypt や Cloudflare には接続しない。

## 未確定・要確認

- ``.deb` のバイナリは `usr/bin/bao`(2.7.2 の実物で確認済み)。.deb は apt では入れず `dpkg-deb -x` で取り出す(パッケージは `openbao` で `bao` と Conflicts)。
- `.deb` の中の `usr/bin/bao` のパス。公式パッケージの構成が違う場合は、setup script の `dpkg-deb -x` 後のパスを直す。
- Cloudflare のトークンは Terraform の state に入る(`data "external"` の結果を provisioner input に渡すため)。既存の SSH 鍵と同じ扱い。state の暗号化は、R2 backend の方針に従う。IP 制限は Cloudflare 側の設定で、この repo からは検証できない。
