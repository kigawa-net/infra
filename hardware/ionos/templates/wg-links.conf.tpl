%{ for l in links ~}
#### ${l.name}
[Interface]
Address = ${l.address}
ListenPort = ${l.listen_port}
PrivateKey = __IONOS_PRIVATE_KEY__
Table = off
MTU = ${mtu}

[Peer]
PublicKey = ${l.peer_public_key}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = ${keepalive}

%{ endfor ~}
