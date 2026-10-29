# 管理者(人間)用。OIDC ログインで付く。日常の Secret 操作と、認証・Policy の管理ができる。
# 付けないもの: sys/raw(バリアの直接読み書き)、sys/seal・sys/step-down、sys/rekey・sys/rotate、sys/audit の変更
# (これらは root token か、Unseal key を持つ人が、必要なときだけ行う)。

path "secret/*"            { capabilities = ["create", "read", "update", "patch", "delete", "list"] }
path "sys/mounts"          { capabilities = ["read", "list"] }
path "sys/mounts/*"        { capabilities = ["create", "read", "update", "delete", "list"] }
path "sys/auth"            { capabilities = ["read", "list"] }
path "sys/auth/*"          { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "auth/*"              { capabilities = ["create", "read", "update", "delete", "list"] }
path "sys/policies/acl"    { capabilities = ["list"] }
path "sys/policies/acl/*"  { capabilities = ["create", "read", "update", "delete", "list"] }
path "sys/audit"           { capabilities = ["read", "list"] }
path "sys/storage/raft/configuration"  { capabilities = ["read"] }
path "sys/storage/raft/autopilot/state" { capabilities = ["read"] }
path "sys/health"          { capabilities = ["read"] }
path "sys/leases/*"        { capabilities = ["read", "list", "update"] }
path "identity/*"          { capabilities = ["create", "read", "update", "delete", "list"] }
