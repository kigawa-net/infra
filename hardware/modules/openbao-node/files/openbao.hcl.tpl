# OpenBao の設定(kigawa-net/infra、hardware/modules/openbao-node が描画する)。手で編集しない。
# 変更は Terraform 側(変数)で行い、適用すると再起動する。
# 証明書(/etc/openbao/tls)は、この設定の外で配置する。秘密鍵をこのファイルに入れない。

ui            = false
log_format    = "json"
disable_mlock = false

# クラスタ内のクライアント・ピアが使う固定アドレス(WireGuard 上)
api_addr     = "https://${wg_address}:8200"
cluster_addr = "https://${wg_address}:8201"

storage "raft" {
  path    = "/var/lib/openbao"
  node_id = "${node_id}"
%{ for p in peers ~}

  retry_join {
    leader_api_addr     = "https://${p.address}:8200"
    leader_ca_cert_file = "/etc/openbao/tls/ca.crt"
  }
%{ endfor ~}
}

# WireGuard の IP だけで待ち受ける(公開 IF には bind しない)。
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
