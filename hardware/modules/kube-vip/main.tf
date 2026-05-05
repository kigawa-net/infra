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
          value: "true"
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
}

resource "null_resource" "kube_vip" {
  triggers = {
    host       = var.host
    pod_yaml   = local.pod_manifest
    vip        = var.vip_address
    interface  = var.interface
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

  provisioner "remote-exec" {
    inline = [
      "echo '${var.sudo_password}' | sudo -S kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f /tmp/kube-vip-rbac.yaml",
      "echo '${var.sudo_password}' | sudo -S cp /tmp/kube-vip-pod.yaml /etc/kubernetes/manifests/kube-vip.yaml",
      "rm -f /tmp/kube-vip-rbac.yaml /tmp/kube-vip-pod.yaml",
    ]
  }
}
