# soichiro を WireGuard 経由で Kubernetes worker に追加する手順

## 1. 前提条件

- soichiro に Ubuntu(k8s-worker5 等と同系統のバージョン)がインストール済みで、SSHで到達可能であること
- **soichiro は Cloudflare Tunnel (`cloudflared access ssh`) 経由でのみSSH到達可能**(直接IPには到達できない)。実際のSSH設定は以下の通り:
  ```
  Host soichiro-oneserver
    HostName ssh.soichiro0520.com
    User kigawa
    ProxyCommand cloudflared access ssh --hostname %h
  ```
  Terraformのネイティブ`connection`ブロック(Go実装のSSHクライアント)は `~/.ssh/config` の `ProxyCommand` を解釈できないため、`hardware/soichiro/` モジュールは他ノードと異なり、ローカルの `ssh`/`scp` コマンド(実行環境のOpenSSH)を `local-exec` から呼び出す方式にしている。**`terraform apply` を実行するマシンに `cloudflared` がインストールされている必要がある。**
- **soichiro自身の資格情報(SSH秘密鍵・sudoパスワード)はBitwardenを使わない。** 他ノードと異なり、ローカルファイル/ローカル変数で直接指定する
  - SSH秘密鍵は手元のファイルパスをそのまま使う(例: `~/.ssh/soichiro`)
  - sudoパスワードは `TF_VAR_sudo_password` 環境変数、またはコミットしない `.auto.tfvars`(`.gitignore`済みであること)経由で渡す。値そのものをリポジトリにコミットしないこと
  - なお、既存クラスタのcontrol-plane(k8s1)へのSSH/sudoは、joinトークン発行のために引き続きBitwardenを使用する(`control_plane_ssh_key_bitwarden_id` / `control_plane_sudo_password_bitwarden_id`、変更不要)

## 2. Terraform 変数を埋める

`hardware/soichiro/variables.tf` の TODO 箇所を実際の値に置き換える:

- `ssh_hostname`: デフォルトの `ssh.soichiro0520.com` のままでよい(変更不要)
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

## 4. ルーティング設計(BGP方式で解決済み)

現在のWireGuardピア設定は、k8s1/k8s2の既存ピアと同様に `AllowedIPs` がトンネルサブネット(`172.31.255.0/24`)のみになっており、これだけではsoichiroからクラスタ側への復路(戻りの経路)は確保されない。alice⇔k8s4間は既存のBGP(FRR/BIRD, AS65020/AS65010)でinuyama(クラスタ)側のルートをやり取りしているため、この復路をBGPで解決した:

- **alice側**: `hardware/alice/variables.tf` の `alice_advertised_prefixes` に `172.31.255.0/24` を追加した。alice自身のWireGuardインターフェース(`wg0`, `172.31.255.2/24`)の直結ルートとして、FRRの `network 172.31.255.0/24` ステートメント経由でinuyama(k8s4)へBGP広告される(`ALICE-OUT` prefix-list、`hardware/alice/templates/frr.conf.tpl`)。
- **k8s4側**: `hardware/k8s4/main.tf` の `module.bgp` の `external_bgp_peers`(alice向けpeerエントリ)の `import_prefixes` を `["172.31.255.0/24"]` に変更した。BIRD(`hardware/modules/bgp-bird`)がこのprefixをalice経由で受理し、`protocol kernel { import all; }` によりkernelのルーティングテーブルにインストールされる。
- k8s4は `bgp_peers`(内部BGPメッシュ、`import all; export all;`)経由でk8s1/k8s2ともこのルートを共有するため、control-planeいずれがAPIサーバーVIPを保持していても、soichiro(`172.31.255.13`)への復路が確保される。

**注意**: この経路は「control-planeノード(k8s1/k8s2/k8s4)からsoichiroへ」到達するためのものであり、192.168.1.0/24 LAN上の他の任意のホスト(worker4等)からsoichiroへの到達性までは保証しない。`kubeadm join`/kubeletのAPIサーバー通信という当面の要件には十分だが、Pod networking(CNI)がLAN全体の経路情報に依存する構成の場合は別途検証が必要。

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
