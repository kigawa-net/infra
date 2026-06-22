[Interface]
Address = ${address}
ListenPort = ${listen_port}
PrivateKey = __ALICE_PRIVATE_KEY__
MTU = ${mtu}

%{ for peer in peers ~}
[Peer]
PublicKey = ${peer.public_key}
AllowedIPs = ${join(", ", peer.allowed_ips)}
%{ if peer.endpoint != "" ~}
Endpoint = ${peer.endpoint}
%{ endif ~}
PersistentKeepalive = ${peer.persistent_keepalive}

%{ endfor ~}
