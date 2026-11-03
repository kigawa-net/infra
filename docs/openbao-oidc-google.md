# OpenBao: Google OIDC(管理者ログイン)の設定手順

#327 Phase 2。`auth/oidc-google` を作り、管理者(1 人)だけが `admin` Policy で入れるようにする。
Microsoft(`oidc-ms`)と Keycloak(`oidc-keycloak`)は、同じ形で後から足す(client の登録後)。

**秘密の扱い**: client secret はチャットに貼らない。bws に入れ、下の手順で標準入力から渡す(コマンドの引数に出さない)。

## 0. 前提(人間の作業)

1. Google Cloud Console で、OAuth クライアント(種類: ウェブアプリケーション)を作る。
   - 承認済みのリダイレクト URI: `http://localhost:8250/oidc/callback`(CLI 用。UI は `ui = false` なので登録しない)
2. client ID と client secret を bws に入れる(別々のシークレット)。
3. 許可するメールアドレスを 1 つ決める(`ADMIN_EMAIL`)。

## 0.5 接続の準備(あなたの端末)

- **`bao` CLI**: サーバと同じ 2.7.2 の `.deb` から `usr/bin/bao` だけを取り出して入れる(`dpkg -i` はサービスが入るので使わない)。
  URL・SHA256 は `hardware/modules/openbao-node/variables.tf` と同じ。
- **接続**: ノードは、オーバーレイの IP とループバックでしか待ち受けない(`bao-02.kigawa.net` は端末から引けない)。
  SSH トンネルで、ループバックの 8200 を転送し、証明書の名前は `BAO_TLS_SERVER_NAME` で合わせる。

```bash
ssh -fN -o ExitOnForwardFailure=yes -L 18200:127.0.0.1:8200 <user>@<bao-02 の IP>   # 終わったら pkill -f 'L 18200:'
export BAO_ADDR=https://127.0.0.1:18200
export BAO_TLS_SERVER_NAME=bao-02.kigawa.net
bao status | grep -E 'Sealed|HA Mode'     # Sealed false / HA Mode active(リーダー)を確認
```

## 1. 設定(Root Token で行う初回だけの作業)

```bash
read -rs BAO_TOKEN; export BAO_TOKEN                 # Initial Root Token を貼る(画面に出ない)

# Policy
bao policy write admin hardware/modules/openbao-node/policies/admin.hcl

# マウント
bao auth enable -path=oidc-google oidc

# 接続設定(client secret は標準入力の JSON で渡す。引数に出さない)
jq -n --arg id "$(bws secret get <CLIENT_ID の bws ID> | jq -r .value)" \
      --arg sec "$(bws secret get <CLIENT_SECRET の bws ID> | jq -r .value)" \
  '{oidc_discovery_url:"https://accounts.google.com", oidc_client_id:$id, oidc_client_secret:$sec, default_role:"admin"}' \
  | bao write auth/oidc-google/config -

# role: このメールアドレスだけを許可する
ADMIN_EMAIL=you@example.com
jq -n --arg mail "$ADMIN_EMAIL" '{
  role_type:"oidc", user_claim:"email", oidc_scopes:["openid","email"],
  allowed_redirect_uris:["http://localhost:8250/oidc/callback"],
  bound_claims:{email:$mail, email_verified:true},
  policies:["admin"], token_ttl:"1h", token_max_ttl:"8h"
}' | bao write auth/oidc-google/role/admin -
```

## 2. 確認

```bash
unset BAO_TOKEN
bao login -method=oidc -path=oidc-google role=admin >/dev/null   # 出力に token が出るので捨てる。ブラウザで Google 認証 → token の policies に admin
bao token lookup | grep -E 'policies|ttl'
bao kv put secret/_oidc_test ok=1 && bao kv delete secret/_oidc_test   # secret/ が KV v2 でなければ先に有効化する
```

別のアカウントでログインして拒否されること(`claim "email" does not match`)も確認する。

## 3. Initial Root Token の失効(確認が通ってから)

OIDC で `admin` に入れることを確認したら、root token を失効する。

```bash
export BAO_TOKEN=...   # Initial Root Token
bao token revoke -self
```

以後に root が必要なときは `bao operator generate-root`(Unseal key 3/5 が要る)。
**注意**: 失効後に Google へ入れなくなると、管理操作ができない。OIDC が壊れた場合の復旧も `generate-root` になる。

## 実施記録

- 2026-10-29: `auth/oidc-google`・`admin` Policy・role を作成。OIDC ログインで `policies [admin default]` を確認。
  admin で `policy list`・`auth list`・`secrets list`・`operator raft list-peers` が通ることを確認(bao-02 leader、bao-03 follower)。
  Initial Root Token を失効した。
- 気づき: `bao login` の出力には token が含まれる。チャットなどに貼らない(貼った場合は `bao token revoke -self`)。
