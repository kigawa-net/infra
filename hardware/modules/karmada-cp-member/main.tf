terraform {
  required_providers {
    null = {
      source = "hashicorp/null"
    }
  }
}

# Karmada の control plane(IONOS = CP #3)を、IaC で構成する(kigawa-net/kigawa-net-k8s#268)。設計と運用: README.md。
# 構成の本体は files/karmada-cp-member.sh(冪等)。**stage = "prepare"(既定)では、何も起動しない**。
#
# 前提と範囲:
#   - 証明書と鍵(/etc/karmada/pki/)は、この IaC の外で用意する(秘密鍵を Terraform の state に入れないため)。
#     kube-apiserver の ServiceAccount の署名鍵(karmada.key)は、管理者権限の鍵に相当する。人の手で配置する。
#   - Inuyama の Karmada(Karmada Operator が Kubernetes 上に作る)とは、同じ etcd(3 メンバー)を共有する別の control plane。
#   - kube-controller-manager は、既定で動かさない(CA の秘密鍵が要るため。variables.tf の enable_kube_controller_manager を参照)。

locals {
  pki        = "/etc/karmada/pki"
  cfg        = "/etc/karmada/config"
  kubeconfig = "/etc/karmada/config/karmada.config"
  webhook    = "/etc/karmada/webhook-cert"
  sbin       = "/usr/local/sbin"
  api_url    = "https://${var.advertise_address}:5443"
  etcd       = join(",", var.etcd_servers)

  # Karmada の登録(webhook は url、APIService は ExternalName)が、`*.karmada-system.svc` の名前で etcd に入っている(全拠点で共通)。
  # この host には Kubernetes の DNS が無いため、名前を別々のループバックに向け、iptables の REDIRECT で、各サービスの実ポートへ転送する。
  # (IONOS の HAProxy が 0.0.0.0:443 を占有しているため、443 では待ち受けられない。REDIRECT なら、衝突しない。コンテナで検証済み)
  # サービスは、127.0.0.1 の別々のポートで待ち受ける(REDIRECT は、宛先を 127.0.0.1 に書き換えるため)。
  names = [
    { name = "karmada-webhook.karmada-system.svc", ip = "127.0.0.11", port = 8443 },
    { name = "karmada-aggregated-apiserver.karmada-system.svc", ip = "127.0.0.12", port = 7443 },
    { name = "karmada-metrics-adapter.karmada-system.svc", ip = "127.0.0.13", port = 7444 },
  ]

  etcd_flags = [
    "--etcd-cafile=${local.pki}/etcd-ca.crt",
    "--etcd-certfile=${local.pki}/etcd-client.crt",
    "--etcd-keyfile=${local.pki}/etcd-client.key",
    "--etcd-servers=${local.etcd}",
  ]
  kc_flags = ["--kubeconfig=${local.kubeconfig}"]
  authn_flags = [
    "--authentication-kubeconfig=${local.kubeconfig}",
    "--authorization-kubeconfig=${local.kubeconfig}",
  ]
  audit_off = ["--audit-log-path=-", "--audit-log-maxage=0", "--audit-log-maxbackup=0"]

  # Inuyama の実機の起動引数(2026-10-10)を、この host 向けに読み替えたもの。読み替えた点は、各行のコメントを参照。
  components = {
    "karmada-apiserver" = {
      desc   = "Karmada API server (kube-apiserver ${var.kubernetes_version})"
      binary = "kube-apiserver"
      needs  = []
      args = concat([
        "--allow-privileged=true",
        "--authorization-mode=Node,RBAC",
        "--client-ca-file=${local.pki}/ca.crt",
        "--disable-admission-plugins=StorageObjectInUseProtection,ServiceAccount",
        "--enable-admission-plugins=NodeRestriction",
        "--enable-bootstrap-token-auth=true",
        "--bind-address=${var.advertise_address}", # Inuyama は 0.0.0.0。この host は公開 IP を持つため、WireGuard のアドレスだけ
        "--secure-port=5443",
        "--service-account-issuer=https://kubernetes.default.svc.cluster.local",
        "--service-account-key-file=${local.pki}/karmada.key",
        "--service-account-signing-key-file=${local.pki}/karmada.key",
        "--service-cluster-ip-range=${var.service_cluster_ip_range}",
        "--proxy-client-cert-file=${local.pki}/front-proxy-client.crt",
        "--proxy-client-key-file=${local.pki}/front-proxy-client.key",
        "--requestheader-allowed-names=front-proxy-client",
        "--requestheader-client-ca-file=${local.pki}/front-proxy-ca.crt",
        "--requestheader-extra-headers-prefix=X-Remote-Extra-",
        "--requestheader-group-headers=X-Remote-Group",
        "--requestheader-username-headers=X-Remote-User",
        "--tls-cert-file=${local.pki}/apiserver.crt",
        "--tls-private-key-file=${local.pki}/apiserver.key",
        "--tls-min-version=VersionTLS13",
        "--max-requests-inflight=400", # Inuyama は 1500 / 500。メモリ 1.8GB の host のため、絞る
        "--max-mutating-requests-inflight=200",
        "--v=2",
      ], local.etcd_flags)
    }
    "karmada-controller-manager" = {
      desc   = "Karmada controller manager"
      binary = "karmada-controller-manager"
      needs  = ["karmada-apiserver"]
      args = concat(local.kc_flags, [
        "--cluster-status-update-frequency=10s",
        "--leader-elect-resource-namespace=karmada-system",
        "--metrics-bind-address=127.0.0.1:18081", # 同じ host で、ポートが衝突しないように割り当てる
        "--health-probe-bind-address=127.0.0.1:10357",
        "--v=2",
      ])
    }
    "karmada-scheduler" = {
      desc   = "Karmada scheduler"
      binary = "karmada-scheduler"
      needs  = ["karmada-apiserver"]
      args = concat(local.kc_flags, [
        "--metrics-bind-address=127.0.0.1:18082",
        "--health-probe-bind-address=127.0.0.1:10351",
        "--enable-scheduler-estimator=true",
        "--leader-elect-resource-namespace=karmada-system",
        "--scheduler-estimator-ca-file=${local.pki}/ca.crt",
        "--scheduler-estimator-cert-file=${local.pki}/ionos-karmada-cp.crt", # Inuyama は karmada.crt / karmada.key(管理者の鍵)。この host 専用の client 証明書を使う
        "--scheduler-estimator-key-file=${local.pki}/ionos-karmada-cp.key",
        "--v=2",
      ])
    }
    "karmada-webhook" = {
      desc   = "Karmada webhook"
      binary = "karmada-webhook"
      needs  = ["karmada-apiserver"]
      args = concat(local.kc_flags, [
        "--bind-address=127.0.0.1", # REDIRECT(127.0.0.11:443 -> 127.0.0.1:8443)の宛先
        "--metrics-bind-address=127.0.0.1:18083",
        "--health-probe-bind-address=127.0.0.1:18003",
        "--secure-port=8443",
        "--cert-dir=${local.webhook}",
        "--v=2",
      ])
    }
    "karmada-aggregated-apiserver" = {
      desc   = "Karmada aggregated API server (cluster.karmada.io)"
      binary = "karmada-aggregated-apiserver"
      needs  = ["karmada-apiserver"]
      args = concat(local.kc_flags, local.authn_flags, [
        "--tls-cert-file=${local.pki}/aggregated-apiserver.crt", # Inuyama は karmada.crt / karmada.key。専用のサービング証明書(CSR 方式)を使う
        "--tls-private-key-file=${local.pki}/aggregated-apiserver.key",
        "--tls-min-version=VersionTLS13",
        "--bind-address=127.0.0.1",
        "--secure-port=7443",
      ], local.audit_off, local.etcd_flags)
    }
    "karmada-metrics-adapter" = {
      desc   = "Karmada metrics adapter"
      binary = "karmada-metrics-adapter"
      needs  = ["karmada-apiserver"]
      args = concat(local.kc_flags, local.authn_flags, [
        "--metrics-bind-address=127.0.0.1:18084",
        "--client-ca-file=${local.pki}/ca.crt",
        "--tls-cert-file=${local.pki}/metrics-adapter.crt",
        "--tls-private-key-file=${local.pki}/metrics-adapter.key",
        "--tls-min-version=VersionTLS13",
        "--bind-address=127.0.0.1",
        "--secure-port=7444",
      ], local.audit_off)
    }
  }

  # 既定は動かさない(variables.tf の説明を参照)。動かす場合も、CA の秘密鍵が要る csrsigning と --cluster-signing-* は外す。
  optional_components = var.enable_kube_controller_manager ? {
    "karmada-kube-controller-manager" = {
      desc   = "Karmada kube-controller-manager (csrsigning なし)"
      binary = "kube-controller-manager"
      needs  = ["karmada-apiserver"]
      args = concat(local.kc_flags, local.authn_flags, [
        "--bind-address=127.0.0.1",
        "--client-ca-file=${local.pki}/ca.crt",
        "--controllers=namespace,garbagecollector,serviceaccount-token,ttl-after-finished,bootstrapsigner,csrcleaner,clusterrole-aggregation",
        "--leader-elect=true",
        "--root-ca-file=${local.pki}/ca.crt",
        "--service-account-private-key-file=${local.pki}/karmada.key",
        "--use-service-account-credentials=true",
        "--v=2",
      ])
    }
  } : {}

  all_components = merge(local.components, local.optional_components)

  units = {
    for name, c in local.all_components : name => join("\n", concat([
      "[Unit]",
      "Description=${c.desc}",
      "After=network-online.target wg-quick@${var.wireguard_interface}.service karmada-cp-redirect.service${join("", [for n in c.needs : " ${n}.service"])}",
      "Wants=network-online.target karmada-cp-redirect.service",
      ],
      length(c.needs) > 0 ? ["Requires=${join(" ", [for n in c.needs : "${n}.service"])}"] : [],
      [
        "",
        "[Service]",
        "Type=simple",
        "User=karmada",
        "Group=karmada",
        "ExecStart=${local.sbin}/${c.binary} \\\n  ${join(" \\\n  ", c.args)}",
        "Restart=on-failure",
        "RestartSec=30",
        "LimitNOFILE=65536",
        # ゲートウェイ(WireGuard / FRR / HAProxy)と etcd を守る: CP のサービスは、1 つの slice にまとめ、メモリの上限を設ける。
        # OOM のとき、CP のサービスを先に落とす。
        "Slice=karmada-cp.slice",
        "OOMScoreAdjust=500",
        "NoNewPrivileges=true",
        "PrivateTmp=true",
        "ProtectHome=true",
        "ProtectSystem=full",
        "",
        "[Install]",
        "WantedBy=multi-user.target",
        "",
    ]))
  }

  slice = join("\n", [
    "[Unit]",
    "Description=Karmada control plane (IONOS) — memory-limited slice",
    "",
    "[Slice]",
    "MemoryHigh=${var.cp_memory_high}",
    "MemoryMax=${var.cp_memory_max}",
    "",
  ])

  redirect_unit = join("\n", [
    "[Unit]",
    "Description=Karmada control plane — loopback REDIRECT for *.karmada-system.svc",
    "After=network-pre.target",
    "Before=${join(" ", [for n in keys(local.all_components) : "${n}.service"])}",
    "",
    "[Service]",
    "Type=oneshot",
    "RemainAfterExit=yes",
    "ExecStart=${local.sbin}/karmada-cp-redirect.sh start",
    "ExecStop=${local.sbin}/karmada-cp-redirect.sh stop",
    "",
    "[Install]",
    "WantedBy=multi-user.target",
    "",
  ])

  # 3 つの名前 -> ループバック、REDIRECT の対応。スクリプトが読む(`name ip port`)
  redirect_table = join("\n", concat([for n in local.names : "${n.ip} ${n.port}"], [""]))
  hosts_block    = join("\n", concat([for n in local.names : "${n.ip}  ${n.name}"], [""]))

  # kubeconfig には、鍵の中身を書かない(パスだけ)。client 証明書と鍵は、この IaC の外で用意する。
  kubeconfig_text = join("\n", [
    "apiVersion: v1",
    "kind: Config",
    "clusters:",
    "  - name: karmada",
    "    cluster:",
    "      server: ${local.api_url}",
    "      certificate-authority: ${local.pki}/ca.crt",
    "users:",
    "  - name: ionos-karmada-cp",
    "    user:",
    "      client-certificate: ${local.pki}/ionos-karmada-cp.crt",
    "      client-key: ${local.pki}/ionos-karmada-cp.key",
    "contexts:",
    "  - name: karmada",
    "    context:",
    "      cluster: karmada",
    "      user: ionos-karmada-cp",
    "current-context: karmada",
    "",
  ])

  # ステージするファイルを、1 つの bundle にまとめる(`@@@ <path> <mode>` の行で区切る)
  files = concat(
    [
      { path = "/etc/systemd/system/karmada-cp.slice", mode = "0644", content = local.slice },
      { path = "/etc/systemd/system/karmada-cp-redirect.service", mode = "0644", content = local.redirect_unit },
      { path = "/etc/karmada/redirect.table", mode = "0644", content = local.redirect_table },
      { path = "/etc/karmada/hosts.block", mode = "0644", content = local.hosts_block },
      { path = local.kubeconfig, mode = "0640", content = local.kubeconfig_text },
    ],
    [for name, text in local.units : { path = "/etc/systemd/system/${name}.service", mode = "0644", content = text }],
  )
  bundle = join("", [for f in local.files : "@@@ ${f.path} ${f.mode}\n${f.content}${endswith(f.content, "\n") ? "" : "\n"}"])

  binaries_manifest = join("\n", concat([
    for name, b in var.binaries : "${name}|${b.source}|${b.ref}|${b.path}|${b.sha256}"
    if name != "kube-controller-manager" || var.enable_kube_controller_manager
  ], [""]))
  crane_manifest = "${var.crane.url}|${var.crane.sha256}\n"

  member_script   = file("${path.module}/files/karmada-cp-member.sh")
  redirect_script = file("${path.module}/files/karmada-cp-redirect.sh")

  stage_dir = "/root/.karmada-cp-member-staging"

  # 起動を許すコンポーネント(stage ごと)
  start_units = {
    prepare   = []
    apiserver = ["karmada-apiserver"]
    full      = keys(local.all_components)
  }
}

resource "null_resource" "karmada_cp_member" {
  triggers = {
    host              = var.host
    stage             = var.stage
    advertise_address = var.advertise_address
    api_sources       = join(",", var.api_allowed_sources)
    bundle_sha        = sha256(local.bundle)
    binaries_sha      = sha256(local.binaries_manifest)
    crane_sha         = sha256(local.crane_manifest)
    script_sha        = sha256(local.member_script)
    redirect_sha      = sha256(local.redirect_script)
    min_mem           = tostring(var.min_available_memory_mb)
    key_fingerprint   = var.karmada_key_fingerprint
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "remote-exec" {
    inline = ["install -d -m 0700 ${local.stage_dir}"]
  }

  provisioner "file" {
    content     = local.member_script
    destination = "${local.stage_dir}/karmada-cp-member.sh"
  }

  provisioner "file" {
    content     = local.redirect_script
    destination = "${local.stage_dir}/karmada-cp-redirect.sh"
  }

  provisioner "file" {
    content     = local.bundle
    destination = "${local.stage_dir}/bundle.txt"
  }

  provisioner "file" {
    content     = local.binaries_manifest
    destination = "${local.stage_dir}/binaries.txt"
  }

  provisioner "file" {
    content     = local.crane_manifest
    destination = "${local.stage_dir}/crane.txt"
  }

  provisioner "remote-exec" {
    inline = [
      "STAGE='${var.stage}' STAGE_DIR='${local.stage_dir}' ADVERTISE='${var.advertise_address}' KARMADA_KEY_FPR='${var.karmada_key_fingerprint}' MIN_MEM_MB='${var.min_available_memory_mb}' API_SOURCES='${join(",", var.api_allowed_sources)}' WG_IF='${var.wireguard_interface}' START_UNITS='${join(" ", local.start_units[var.stage])}' ALL_UNITS='${join(" ", keys(local.all_components))}' bash ${local.stage_dir}/karmada-cp-member.sh",
    ]
  }
}
