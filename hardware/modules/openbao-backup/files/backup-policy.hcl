# openbao-backup 用の AppRole の policy(バックアップ専用)。
# Raft スナップショットの取得(GET /v1/sys/storage/raft/snapshot)だけを許す。
# 復元(snapshot restore)・読み書き・監査・ほかの管理操作は、持たない。復元は人間の管理者だけが行う。
# 適用: bao policy write openbao-backup hardware/modules/openbao-backup/files/backup-policy.hcl
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
