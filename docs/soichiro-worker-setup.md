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
  Terraformのネイティブ`connection`ブロック(Go実装のSSHクライアント)は `~/.ssh/config` の `ProxyCommand` を解釈できないため、`hardware/soichiro/` モジュールと `hardware/ionos/` モジュールのsoichiro向け公開鍵取得処理は、ローカルの `ssh`/`scp` コマンド(実行環境のOpenSSH)を使う方式にしている。**`terraform apply` を実行するマシンに `cloudflared` がインストールされている必要がある。**
- **WireGuardのハブは `alice` ではなく `ionos` を使う。** alice(`161.248.62.66`)は廃止済みのため、恒久的なゲートウェイである `hardware/ionos`(`74.208.55.86`)に接続する。
- **soichiroのSSH秘密鍵・sudoパスワードは他ホスト(k8s1/k8s2/alice/ionos)と共通**であり、既存のBitwarden secret(`0393671f-6ef0-4650-be98-b364013f8644` / `52b44d60-7cab-429f-929a-b4340139b6d8`)をそのまま使う。新規登録は不要。

## 2. Terraform 変数を確認する

`hardware/soichiro/variables.tf` は基本的にデフォルト値のままで動作する(SSH鍵・sudoパスワードとも既存のBitwarden secretを再利用するため)。`ssh_hostname` もデフォルトの `ssh.soichiro0520.com` のままでよい。

## 3. 適用順序

ionos側のsoichiro公開鍵取得は `data "external" "soichiro_wireguard_public_key"` がSSH経由で自動取得するため、alice方式(手動でのコピペ往復)と異なり手動での鍵交換は不要。

1. **soichiro側を先に適用**してWireGuardクライアントとkubelet等の前提パッケージをセットアップする:
   ```bash
   ./hardware/run.sh soichiro apply
   ```
   この時点ではionos側にsoichiroのpeer設定がまだ無いため、`kubeadm join` はAPIサーバーに到達できず失敗する可能性が高い。失敗した場合は一旦無視して次に進む。

2. **ionos側を適用**する。ionosがSSH経由でsoichiroの公開鍵を自動取得してpeerとして登録する:
   ```bash
   ./hardware/run.sh ionos apply
   ```

3. **soichiro側を再適用**してkubeadm joinを完了させる:
   ```bash
   ./hardware/run.sh soichiro apply
   ```

## 4. ルーティング設計(BGP方式)

現在のWireGuardピア設定は、k8s1/k8s2の既存ピアと同様に `AllowedIPs` がトンネルサブネット(`172.31.254.0/24`)のみになっており、これだけではsoichiroからクラスタ側への復路(戻りの経路)は確保されない。ionos⇔k8s4間は既存のBGP(FRR/BIRD)でinuyama(クラスタ)側のルートをやり取りしているため、この復路をBGPで解決した:

- **ionos側**: `hardware/ionos/variables.tf` の `ionos_advertised_prefixes` に `172.31.254.0/24` を追加した。ionos自身のWireGuardインターフェース(`wg0`, `172.31.254.2/24`)の直結ルートとして、FRRの `network 172.31.254.0/24` ステートメント経由でinuyama(k8s4)へBGP広告される(`IONOS-OUT` prefix-list、`hardware/ionos/templates/frr.conf.tpl`)。
- **k8s4側**: `hardware/k8s4/main.tf` の `module.bgp` の `external_bgp_peers`(ionos向けpeerエントリ)の `import_prefixes` を `["172.31.254.0/24"]` に変更した。BIRD(`hardware/modules/bgp-bird`)がこのprefixをionos経由で受理し、`protocol kernel { import all; }` によりkernelのルーティングテーブルにインストールされる。
- k8s4は `bgp_peers`(内部BGPメッシュ、`import all; export all;`)経由でk8s1/k8s2ともこのルートを共有するため、control-planeいずれがAPIサーバーVIPを保持していても、soichiro(`172.31.254.13`)への復路が確保される。

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
