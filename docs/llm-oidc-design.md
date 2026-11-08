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
  - `--provider=oidc`、`--oidc-issuer-url=https://user.kigawa.net/realms/<realm>`、`--skip-jwt-bearer-tokens=true`、`--oidc-extra-audience=litellm`。
  - サービスアカウントのトークンには email が無いので、`--oidc-email-claim=sub` を使う。
  - **Authorization の置き換え**: `--pass-authorization-header` のままだと Keycloak の JWT が LiteLLM に渡り、不正なキーとして拒否される。alpha config の `injectRequestHeaders`(`secretSource: fromEnv`)で、`Authorization: Bearer <LiteLLM の仮想キー>` に置き換える。仮想キーは Dev Pod に渡らない。
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
5. 検証: client_credentials で取得した JWT で `/v1/models` と推論が通ること。JWT なし・期限切れ・別 audience が 401/403 になること。

## 6. 未確認事項

- oauth2-proxy が、Bearer の JWT で認証済みセッションにした上で `injectRequestHeaders` を適用するか(実機で要確認。だめなら nginx などで Authorization を付け替える)。
- vLLM の KV キャッシュは約 25,000 トークン(コンテキスト 16k で同時 1.5 本)。OpenCode の重い作業には窮屈。
- Keycloak の realm(`manage` は ArgoCD MCP 用。開発用の `develop` が候補)。
