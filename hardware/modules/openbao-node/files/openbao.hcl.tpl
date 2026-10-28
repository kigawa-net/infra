# OpenBao の設定(kigawa-net/infra、hardware/modules/openbao-node が描画する)。手で編集しない。
# 変更は Terraform 側(変数)で行い、適用すると再起動する。
# 証明書(/etc/openbao/tls)は、ノード自身が certbot で発行・更新する。秘密鍵をこのファイルに入れない。

ui            = false
log_format    = "json"
# OpenBao 2.x は mlock をやめた(disable_mlock を書くと、起動に失敗する)。メモリを swap に出さない対策は、swap を無効にする(このホストは swap なし)か、暗号化する

# api_addr は証明書の名前(fqdn。/etc/hosts で、このノードのアドレスに向けている)
# cluster_addr は Raft のネットワーク上の固定 IP(8201 はピア同士の raft 通信。WireGuard か、EasyTier のオーバーレイ)
api_addr     = "https://${fqdn}:8200"
cluster_addr = "https://${wg_address}:8201"

storage "raft" {
  path    = "/var/lib/openbao"
  node_id = "${node_id}"
%{ for p in peers ~}

  # ピアの証明書は公開 CA(Let's Encrypt)で発行されるので、OS の信頼ストアで検証する(leader_ca_cert_file は不要)
  retry_join {
    leader_api_addr = "https://${p.fqdn}:8200"
  }
%{ endfor ~}
}

# Raft のネットワーク上の IP だけで待ち受ける(公開 IF には bind しない)。
# ループバックは、同じノード上の bao CLI 用。
listener "tcp" {
  address         = "${wg_address}:8200"
  cluster_address = "${wg_address}:8201"
  tls_cert_file   = "/etc/openbao/tls/tls.crt"
  tls_key_file    = "/etc/openbao/tls/tls.key"
  tls_min_version = "tls13"
}

listener "tcp" {
  address         = "127.0.0.1:8200"
  cluster_address = "127.0.0.1:8201"
  tls_cert_file   = "/etc/openbao/tls/tls.crt"
  tls_key_file    = "/etc/openbao/tls/tls.key"
  tls_min_version = "tls13"
}

# メトリクスは認証必須。Prometheus は、sys/metrics の read だけを持つ専用 token で scrape する。
telemetry {
  unauthenticated_metrics_access = false
}
