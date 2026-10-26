# openbao-node

OpenBao のノード(raft の voter 1 台)を、SSH provisioner で構築する module。設計は `docs/openbao-implementation-design.md` §2、issue kigawa-net/infra#327 の Phase 1。

呼び出し元: `hardware/bao-02/`(`enabled = false` の間は、何も作らず Bitwarden にも触れない)。

## 構成

| ファイル | 役割 |
|---|---|
| `main.tf` | `null_resource`。設定・unit・証明書を stage に置き、setup script を sudo 経由で bash 実行する |
| `variables.tf` | 入力。TLS の PEM と sudo パスワードは `sensitive` |
| `files/openbao.hcl.tpl` | `/etc/openbao/openbao.hcl` の描画元(`templatefile`) |
| `files/openbao-node-setup.sh` | 構築・更新の本体(冪等) |
| `test-openbao-node.sh` | オフラインのテスト(設定の描画、setup script の挙動) |

## 何をするか

1. 公式の `.deb` を、**固定バージョン**で取得し、**SHA256 を検証**してから、`dpkg-deb -x` で `bao` を取り出す(`apt` は使わない)。
2. 専用ユーザー `openbao`(system、ログイン不可)、`/var/lib/openbao`(0700、ローカルの ext4 を想定)、`/etc/openbao`。
3. TLS の証明書・秘密鍵・CA を `/etc/openbao/tls/` に 0600・openbao 所有で置く。**この module は証明書を発行しない**。
4. `openbao.hcl`(raft、retry_join、listener 8200/8201 を WireGuard IP と loopback のみ、`tls_min_version = "tls13"`、telemetry の認証必須、ui 無効)と `openbao.service` を置く。
5. `systemctl enable --now`。設定・unit が変わったら再起動、**証明書だけ変わったときは `systemctl reload`(SIGHUP)**。

### systemd unit の硬化

`User=openbao`、`NoNewPrivileges`、`ProtectSystem=strict`、`ProtectHome`、`PrivateTmp`、`PrivateDevices`、`MemoryDenyWriteExecute`、`LimitCORE=0`、`SystemCallFilter=@system-service`、`CapabilityBoundingSet=CAP_IPC_LOCK`(mlock のため)。データは `StateDirectory=openbao` で `/var/lib/openbao` だけに書ける。

### mlock と swap

`disable_mlock = false` とし、`LimitMEMLOCK=infinity` と `CAP_IPC_LOCK` で mlock を有効にする。swap の有無に依存しない。

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
| `peers` | `[]` | 他のノード。`{node_id, address}`。自分自身は無視される |
| `openbao_version` | (必須) | `X.Y.Z` 固定。`latest` は不可 |
| `openbao_deb_sha256` | `""` | 公式 `.deb` の SHA256。空のままでは apply できない(precondition) |
| `tls_cert_pem` / `tls_key_pem` / `tls_ca_pem` | `""` | `sensitive`。空では apply できない(precondition) |
| `wipe_data_on_failure` | `false` | 失敗時に `/var/lib/openbao` を消すか |

`.deb` の URL は `https://github.com/openbao/openbao/releases/download/v<version>/bao_<version>_linux_amd64.deb` を使う。

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
- 確認内容: 描画(listener、tls13、retry_join、telemetry)、秘密鍵 0600、再実行の冪等性、証明書変更時の reload のみ、SHA256 不一致、起動失敗時の巻き戻し、`wipe_data_on_failure` の挙動、`operator init` が呼ばれないこと。

## 未確定・要確認

- `openbao_version` の既定(2.1.0)と、`openbao_deb_sha256`(未設定)。実際のリリースの checksum を確認してから設定すること。
- `.deb` の中の `usr/bin/bao` のパス。公式パッケージの構成が違う場合は、setup script の `dpkg-deb -x` 後のパスを直す。
- 証明書・秘密鍵の PEM は Terraform の state に入る(`data "external"` の結果)。既存の SSH 鍵と同じ扱い。state の暗号化は、R2 backend の方針に従う。
