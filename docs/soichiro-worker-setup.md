# soichiro を WireGuard 経由で Kubernetes worker に追加する手順

## 1. 前提条件

- soichiro に Ubuntu(k8s-worker5 等と同系統のバージョン)がインストール済みで、SSHで到達可能であること
- **soichiro自身の資格情報(SSH秘密鍵・sudoパスワード)はBitwardenを使わない。** 他ノードと異なり、ローカルファイル/ローカル変数で直接指定する
  - SSH秘密鍵は手元のファイルパスをそのまま使う(例: `~/.ssh/soichiro`)
  - sudoパスワードは `TF_VAR_sudo_password` 環境変数、またはコミットしない `.auto.tfvars`(`.gitignore`済みであること)経由で渡す。値そのものをリポジトリにコミットしないこと
  - なお、既存クラスタのcontrol-plane(k8s1)へのSSH/sudoは、joinトークン発行のために引き続きBitwardenを使用する(`control_plane_ssh_key_bitwarden_id` / `control_plane_sudo_password_bitwarden_id`、変更不要)

## 2. Terraform 変数を埋める

`hardware/soichiro/variables.tf` の TODO 箇所を実際の値に置き換える:

- `host`: soichiro への直接SSH到達アドレス(パブリックIPまたは現在のLAN上のIP。WireGuardのトンネルアドレスではない)
- `ssh_private_key_path`: soichiro用SSH秘密鍵のローカルファイルパス(例: `~/.ssh/soichiro`)
- `sudo_password`: soichiro自身のsudoパスワード。`variables.tf` のdefaultには入れず、`TF_VAR_sudo_password=... ./hardware/run.sh soichiro apply` のように環境変数で渡すこと

## 3. 適用順序

WireGuardのピア関係は双方向に鍵を登録し合う必要があるため、以下の順序で進める。

1. **soichiro側を先に適用**してWireGuardクライアントとkubelet等の前提パッケージをセットアップする:
   ```bash
   ./hardware/run.sh soichiro apply
   ```
   この時点では `wireguard_server_public_key` はalice側の既存の公開鍵のままでよい(alice→soichiro方向は最初から疎通する必要はない)。ただし `kubeadm join` はAPIサーバーに到達できないため失敗する可能性が高い。失敗した場合は一旦無視して次に進む。

2. soichiro にSSHし、生成された公開鍵を確認する:
   ```bash
   ssh <soichiroのhost> cat /etc/wireguard/publickey
   ```

3. **alice側の変数を更新**する。`hardware/alice/variables.tf` の `soichiro_wireguard_public_key` に手順2で取得した公開鍵を設定し、適用する:
   ```bash
   ./hardware/run.sh alice apply
   ```
   これでaliceがsoichiroをWireGuardピアとして認識する。

4. **soichiro側を再適用**してkubeadm joinを完了させる:
   ```bash
   ./hardware/run.sh soichiro apply
   ```

## 4. 重要な注意点(未解決の設計課題)

現在のWireGuardピア設定は、k8s1/k8s2の既存ピアと同様に `AllowedIPs` がトンネルサブネット(`172.31.255.0/24`)のみになっており、**これだけではsoichiroからクラスタLAN(`10.0.0.0/24`、APIサーバーVIP `10.0.0.100:6443` を含む)への実際の経路は確保されない**。

alice⇔k8s4間は既存のBGP(FRR/BIRD, AS65020/AS65010)でinuyama(クラスタ)側のルートをやり取りしているため、soichiroの経路をクラスタに伝播するには、次のいずれかの追加作業が必要:

- **(a) alice の FRR 設定を拡張する**: `hardware/alice/templates/frr.conf.tpl` にsoichiro向けのネットワークステートメント/redistributeを追加してBGP経由で経路広告する
- **(b) k8s4側に静的ルートを追加する**: `172.31.255.0/24 via <aliceのinuyama向けWireGuard IP>` をk8s4に追加する

**このドキュメントではどちらの方式にするかを決め打ちしていない。** 実際に適用する前に現在のFRR/BIRD設定(`hardware/alice/templates/frr.conf.tpl` とk8s4上のBIRD設定)を確認し、ネットワーク設計者の判断を仰ぐこと。ここを解決しないと、soichiroはWireGuardトンネル自体は確立できても `kubeadm join` がAPIサーバーに到達できず失敗し続ける可能性が高い。

## 5. 動作確認

1. WireGuardハンドシェイクの確認(soichiro側):
   ```bash
   sudo wg show
   ```
   `latest handshake` が数十秒〜数分以内で更新されていればOK。

2. クラスタLANへの疎通確認(soichiro側、上記4のルーティング対応後):
   ```bash
   ping 10.0.0.100
   ```

3. ノード登録確認(既存のcontrol-planeから):
   ```bash
   kubectl get nodes
   ```
   `soichiro` が `Ready` になっていることを確認する。
