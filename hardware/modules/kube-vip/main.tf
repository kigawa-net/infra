locals {
  rbac_yaml = <<-RBAC
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: kube-vip
      namespace: kube-system
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      annotations:
        rbac.authorization.kubernetes.io/autoupdate: "true"
      name: system:kube-vip-role
    rules:
    - apiGroups: [""]
      resources: ["services/status"]
      verbs: ["update"]
    - apiGroups: [""]
      resources: ["services", "endpoints"]
      verbs: ["list","get","watch","update"]
    - apiGroups: [""]
      resources: ["nodes"]
      verbs: ["list","get","watch","update","patch"]
    - apiGroups: ["coordination.k8s.io"]
      resources: ["leases"]
      verbs: ["list","get","watch","create","update"]
    - apiGroups: ["discovery.k8s.io"]
      resources: ["endpointslices"]
      verbs: ["list","get","watch","update"]
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: system:kube-vip-binding
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: system:kube-vip-role
    subjects:
    - kind: ServiceAccount
      name: kube-vip
      namespace: kube-system
    RBAC

  pod_manifest = <<-POD
    apiVersion: v1
    kind: Pod
    metadata:
      name: kube-vip
      namespace: kube-system
    spec:
      containers:
      - name: kube-vip
        image: ${var.kube_vip_image}
        imagePullPolicy: IfNotPresent
        args:
        - manager
        env:
        - name: vip_arp
          value: "false"
        - name: bgp_enable
          value: "true"
        - name: bgp_routerid
          value: ${var.vip_address}
        - name: bgp_as
          value: "${var.kube_vip_bgp_as}"
        - name: bgp_peeraddress
          value: "127.0.0.2"
        - name: bgp_peeras
          value: "${var.bgp_peer_as}"
        - name: PORT
          value: "${var.k8s_port}"
        - name: vip_interface
          value: ${var.interface}
        - name: address
          value: ${var.vip_address}
        - name: cp_enable
          value: "true"
        - name: cp_namespace
          value: kube-system
        - name: vip_leaderelection
          value: "true"
        securityContext:
          capabilities:
            add:
            - NET_ADMIN
            - NET_RAW
            - SYS_TIME
        # kube-vipのプロセス自体は生存しているがBGP側のBirdルートが壊れ
        # (`unreachable ${var.vip_address}` になる)VIPに到達できなくなる障害が
        # 実際に発生した。kubeletのデフォルトのプロセス生存確認だけではこれを
        # 検知できない。kube-vipのイメージは`ip`はおろか`which`すら無い最小
        # イメージのため execプローブは使えず(execなら常に失敗して逆に恒常的
        # クラッシュループを招く)、hostNetwork:trueを利用してkubelet自身が
        # ホストのネットワークスタックから直接VIPへHTTPSリクエストする
        # httpGetプローブでVIPへの実際の到達性を確認する
        # (httpGetはTLS証明書検証を行わないためVIP自身の証明書でも問題ない)。
        livenessProbe:
          httpGet:
            path: /livez
            host: ${var.vip_address}
            port: ${var.k8s_port}
            scheme: HTTPS
          initialDelaySeconds: 15
          periodSeconds: 15
          timeoutSeconds: 5
          failureThreshold: 3
        volumeMounts:
        - mountPath: /etc/kubernetes/admin.conf
          name: kubeconfig
          readOnly: true
      hostNetwork: true
      hostAliases:
      - ip: ${var.api_server_ip}
        hostnames:
        - kubernetes
      volumes:
      - hostPath:
          path: /etc/kubernetes/admin.conf
        name: kubeconfig
    POD

  health_script = file("${path.module}/files/kube-vip-health.sh")

  health_service = <<-UNIT
    [Unit]
    Description=Stop kube-vip when the local kube-apiserver is unhealthy (issue #232)

    [Service]
    Type=oneshot
    Environment=VIP=${var.vip_address}
    Environment=IFACE=${var.interface}
    Environment=API_PORT=${var.k8s_port}
    Environment=FAIL_THRESHOLD=${var.health_fail_threshold}
    Environment=OK_THRESHOLD=${var.health_ok_threshold}
    Environment="PEERS=${join(" ", var.health_peers)}"
    Environment=ENABLED=${var.enabled}
    ExecStart=/usr/local/bin/kube-vip-health.sh
    UNIT

  health_timer = <<-UNIT
    [Unit]
    Description=Check the local kube-apiserver for kube-vip (issue #232)

    [Timer]
    OnBootSec=60
    OnUnitActiveSec=${var.health_interval_seconds}
    AccuracySec=1

    [Install]
    WantedBy=timers.target
    UNIT

  sudo = "echo '${var.sudo_password}' | sudo -S"
}

resource "null_resource" "kube_vip" {
  triggers = {
    host      = var.host
    pod_yaml  = local.pod_manifest
    vip       = var.vip_address
    interface = var.interface
    enabled   = tostring(var.enabled)
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.rbac_yaml
    destination = "/tmp/kube-vip-rbac.yaml"
  }

  provisioner "file" {
    content     = local.pod_manifest
    destination = "/tmp/kube-vip-pod.yaml"
  }

  # enabled=false でこのノードの static pod を撤去し、kube-vip の
  # リーダー選出/BGP VIP広報から一時的に除外する (ローカルディスク障害等で
  # apiserverがクラッシュループしている間の緩和策として使う想定)。
  provisioner "remote-exec" {
    inline = [
      var.enabled ? "echo '${var.sudo_password}' | sudo -S kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f /tmp/kube-vip-rbac.yaml" : "true",
      # Terraform が書いた(または意図的に外した)状態を優先する。ヘルスチェックが退避した
      # 古いコピーが残っていると、後で復元されて、新しいマニフェストや enabled=false を覆すため、
      # 一緒に消す。ヘルスチェック(kube-vip-health.sh)と同じロックで直列化する。さもないと、
      # 書いた直後のマニフェストをチェックが退避し、そのコピーを私たちが消して、どちらも残らない。
      # (チェックは flock -n なので、ロック中の tick は飛ばされるだけ)
      var.enabled
      ? "echo '${var.sudo_password}' | sudo -S bash -c 'mkdir -p /var/lib/kube-vip-health && flock /var/lib/kube-vip-health/lock bash -c \"cp /tmp/kube-vip-pod.yaml /etc/kubernetes/manifests/kube-vip.yaml && rm -f /var/lib/kube-vip-health/kube-vip.yaml\"'"
      : "echo '${var.sudo_password}' | sudo -S bash -c 'mkdir -p /var/lib/kube-vip-health && flock /var/lib/kube-vip-health/lock bash -c \"rm -f /etc/kubernetes/manifests/kube-vip.yaml /var/lib/kube-vip-health/kube-vip.yaml\"'",
      "rm -f /tmp/kube-vip-rbac.yaml /tmp/kube-vip-pod.yaml",
    ]
  }
}

# ローカルの kube-apiserver が応答しないとき、このノードの kube-vip を一時的に止めて VIP を別ノードへ移す。
# kube-vip のリーダーのノードで、OS と BGP デーモンは生きているが apiserver だけがハングすると、
# VIP の経路が撤回されない問題 (issue #232) への対策。kube-vip 本体のリソースとは分けて、
# ヘルスチェックの設定を変えても、kube-vip の static pod のマニフェストを書き直さないようにする。
resource "null_resource" "kube_vip_health" {
  depends_on = [null_resource.kube_vip]

  triggers = {
    host        = var.host
    enabled     = tostring(var.health_check_enabled)
    script_sha  = sha256(local.health_script)
    service_sha = sha256(local.health_service)
    timer_sha   = sha256(local.health_timer)
  }

  connection {
    type        = "ssh"
    host        = var.host
    user        = var.ssh_user
    private_key = var.ssh_private_key
  }

  provisioner "file" {
    content     = local.health_script
    destination = "/tmp/kube-vip-health.sh"
  }

  provisioner "file" {
    content     = local.health_service
    destination = "/tmp/kube-vip-health.service"
  }

  provisioner "file" {
    content     = local.health_timer
    destination = "/tmp/kube-vip-health.timer"
  }

  provisioner "remote-exec" {
    inline = concat(
      var.health_check_enabled ? [
        "${local.sudo} install -m 0755 /tmp/kube-vip-health.sh /usr/local/bin/kube-vip-health.sh",
        "${local.sudo} install -m 0644 /tmp/kube-vip-health.service /etc/systemd/system/kube-vip-health.service",
        "${local.sudo} install -m 0644 /tmp/kube-vip-health.timer /etc/systemd/system/kube-vip-health.timer",
        "${local.sudo} systemctl daemon-reload",
        "${local.sudo} systemctl enable kube-vip-health.timer",
        "${local.sudo} systemctl restart kube-vip-health.timer",
        ] : [
        # 無効化: timer を止め、実行中のチェックも止めてから(チェックの途中で、あとから退避されるのを防ぐ)、
        # 退避中のマニフェストがあれば戻す(止めたまま放置しない)。ただし kube-vip を意図的に外している
        # (enabled=false)ときは戻さない。マニフェストのディレクトリは root 専用(0700)なので、存在の確認は sudo で行う。
        "${local.sudo} systemctl disable --now kube-vip-health.timer || true",
        "${local.sudo} systemctl stop kube-vip-health.service || true",
        var.enabled ? "if ${local.sudo} test -f /var/lib/kube-vip-health/kube-vip.yaml && ! ${local.sudo} test -f /etc/kubernetes/manifests/kube-vip.yaml; then ${local.sudo} mv /var/lib/kube-vip-health/kube-vip.yaml /etc/kubernetes/manifests/kube-vip.yaml; fi" : "true",
      ],
      ["rm -f /tmp/kube-vip-health.sh /tmp/kube-vip-health.service /tmp/kube-vip-health.timer"],
    )
  }
}
