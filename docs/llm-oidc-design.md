# 開発環境から本番の LLM を OIDC(Keycloak)で呼ぶ 設計書(ドラフト)

2026-11-09 時点。関連: `docs/gpu-node-design.md`、infra #470(開発環境の公開)、kigawa-net-k8s の `litellm/` `vllm/`。

## 1. 目的

自宅 main の開発環境(OpenCode + code-server の Dev Pod)から、本番クラスタの LLM(worker5 の vLLM、モデル `production-llm`)を使う。認証は **OIDC(Keycloak)** で行い、共有の固定キーを Dev Pod に持たせない。

## 2. 現状

- LiteLLM は `https://litellm.kigawa.net`(Ingress、`litellm-service`、master key 認証)で公開済み。`production-llm` は vLLM(`vllm-openai-service`)に向いている。
- open-webui は内部 URL(`litellm-service.kigawa-net-llm-proxy.svc`)で LiteLLM を呼ぶ。外部の Ingress を変えても影響しない。
- DNS は Cloudflare の `*` ワイルドカードがあり、新しいホスト名に DNS の変更は要らない。
- LiteLLM の JWT 認証はエンタープライズ機能の認識(要確認)。リポジトリには oauth2-proxy を Bearer 専用で前段に置く実績がある(`oneserver-files/`)。

## 3. 設計

```
Dev Pod (自宅 main)
 ├ OpenCode ──http──> localhost:4000 (中継プロキシ)
 │                      └ Keycloak から client_credentials で JWT を取得・更新
 └──────────https + Authorization: Bearer <JWT>──────────────┐
                                                             ▼
                    litellm-api.kigawa.net (HAProxy Ingress)
                                                             ▼
                    oauth2-proxy (Bearer 専用、Keycloak の JWT を検証)
                      └ Authorization を LiteLLM の仮想キーに置き換える
                                                             ▼
                    litellm-service (仮想キー認証) ──> vllm-openai-service
```

- **新しいホスト `litellm-api.kigawa.net`** を使う。既存の `litellm.kigawa.net`(master key、管理 UI)は変えない。
- **oauth2-proxy**(`litellm` namespace):
  - **alpha config に一本化する**: `--alpha-config` を使うと `--provider` などの従来フラグは使えない(`unknown flag` で起動しない)。provider(`oidc`、issuer `https://user.kigawa.net/realms/develop`)・upstream・`injectRequestHeaders` は alpha config に書く。フラグは `--skip-jwt-bearer-tokens=true` と `--email-domain=*` だけ。
  - `oidcConfig`: `extraAudiences: [litellm]`、サービスアカウントのトークンには email が無いので `emailClaim: sub`。
  - **Authorization の置き換え**: `injectRequestHeaders` に `fromEnv: LITELLM_AUTH_HEADER`(v7.7.1 では `secretSource:` を付けるとエラー)。env は Deployment 側で `Bearer $(LITELLM_VIRTUAL_KEY)` と組み立てる。仮想キーは Dev Pod に渡らない。**実機で動作を確認済み**。
- **LiteLLM の仮想キー**(`opencode-dev`): master key は使わない。許可モデルは `production-llm` のみ、RPM と並列数を制限する。
- **Keycloak クライアント**(`opencode-dev`): confidential、Service Accounts 有効、audience mapper(`litellm`)。client secret は Bitwarden SM に置く。
- **Dev Pod の中継プロキシ**: localhost で待ち受け、client_credentials で取得・更新したトークンを付けて転送する。OpenCode は `baseURL: http://localhost:4000/v1` を向けるだけで、更新を意識しない。

## 4. 前提作業(認証情報を作る。実行前に承認が要る)

1. Keycloak にクライアント `opencode-dev` を作る(realm は要確定)。
2. LiteLLM に仮想キーを作る(master key で `/key/generate`)。Bitwarden SM に保存し、`litellm` namespace に同期する。
3. Dev Pod 用に、Keycloak の client secret を Bitwarden SM 経由で自宅 main に届ける。

## 5. 実装の流れ

1. 前提作業(上記)。
2. kigawa-net-k8s: oauth2-proxy(Deployment・Service・alpha config)と Ingress `litellm-api.kigawa.net`。
3. vLLM に tool calling を有効にする(`--enable-auto-tool-choice --tool-call-parser hermes`)。OpenCode のエージェントに必要。
4. Dev Pod の中継プロキシと OpenCode の設定。
5. 検証: client_credentials で取得した JWT で `/v1/models` と推論が通ること。JWT なし・改ざん・任意の文字列が拒否されること(oauth2-proxy のサインインページ付き 403。401 ではない)。

## 6. 実装状況と未確認事項

実装済み・検証済み(2026-11-09):

- Keycloak クライアント `opencode-dev`、LiteLLM 仮想キー `opencode-dev`(`production-llm` のみ、rpm 60、並列 4。`gpt-4o` などは 403)。
- oauth2-proxy と Ingress `litellm-api.kigawa.net`(kigawa-net-k8s #498、#501)。有効な JWT で `production-llm` が 200、JWT なし・改ざん・任意の文字列は 403。
- vLLM の tool calling(kigawa-net-k8s #491)。

未実装・未確認:

- Dev Pod の中継プロキシと OpenCode の設定(Dev Pod の置き場所の確認が先)。
- vLLM の KV キャッシュは約 25,000 トークン(コンテキスト 16k で同時 1.5 本)。OpenCode の重い作業には窮屈。
- JWT の失効はトークンの有効期限(`exp`)まで効く。キーの失効は LiteLLM 側の仮想キー削除で行う。
