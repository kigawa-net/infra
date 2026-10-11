%{ for l in links ~}
#### ${l.name}
[Interface]
Address = ${l.address}
ListenPort = ${l.listen_port}
PrivateKey = __IONOS_PRIVATE_KEY__
Table = off
MTU = ${mtu}
%{ for r in l.static_routes ~}
PostUp = ip route replace ${r} via ${l.peer_address} dev ${l.name} metric 100 || true
PostDown = ip route del ${r} via ${l.peer_address} dev ${l.name} metric 100 2>/dev/null || true
%{ endfor ~}

[Peer]
PublicKey = ${l.peer_public_key}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = ${keepalive}

%{ endfor ~}
