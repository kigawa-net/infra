[Interface]
Address = ${address}
ListenPort = ${listen_port}
PrivateKey = __ALICE_PRIVATE_KEY__
MTU = ${mtu}

%{ if peer_public_key != "" ~}
[Peer]
PublicKey = ${peer_public_key}
AllowedIPs = ${peer_allowed_ips}
%{ if peer_endpoint != "" ~}
Endpoint = ${peer_endpoint}
%{ endif ~}
PersistentKeepalive = ${persistent_keepalive}
%{ endif ~}
