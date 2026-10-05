frr defaults traditional
hostname frr
log syslog informational
service integrated-vtysh-config
!
ip prefix-list IONOS-HELPER seq 10 permit 172.31.254.2/32
route-map IBGP-OUT deny 10
 match ip address prefix-list IONOS-HELPER
route-map IBGP-OUT permit 20
! Filter BGP FIB installs; this does not reproduce BIRD kernel learn/persist.
route-map BGP-TO-KERNEL deny 10
 match ip address prefix-list IONOS-HELPER
route-map BGP-TO-KERNEL permit 20
ip protocol bgp route-map BGP-TO-KERNEL
!
route-map KUBE-VIP-IN permit 10
 set ip next-hop ${bgp_router_id}
route-map KUBE-VIP-OUT deny 10
!
! BIRD の protocol direct 相当は、許可リスト方式で直結経路だけを再配布する。
%{ for idx, prefix in redistribute_connected_prefixes ~}
ip prefix-list CONNECTED-ALLOW seq ${(idx + 1) * 10} permit ${prefix}
%{ endfor ~}
%{ if length(redistribute_connected_prefixes) > 0 ~}
route-map CONNECTED-TO-BGP permit 10
 match ip address prefix-list CONNECTED-ALLOW
%{ endif ~}
route-map CONNECTED-TO-BGP deny 100
!
%{ for idx, peer in external_bgp_peers ~}
%{ for pidx, prefix in peer.import_prefixes ~}
ip prefix-list EXT-${idx}-IN seq ${(pidx + 1) * 10} permit ${prefix}
%{ endfor ~}
%{ if length(peer.import_prefixes) > 0 ~}
route-map EXT-${idx}-IN permit 10
 match ip address prefix-list EXT-${idx}-IN
%{ if peer.local_pref != null ~}
 set local-preference ${peer.local_pref}
%{ endif ~}
%{ endif ~}
route-map EXT-${idx}-IN deny 100
%{ for pidx, prefix in peer.export_prefixes ~}
ip prefix-list EXT-${idx}-OUT seq ${(pidx + 1) * 10} permit ${prefix}
%{ endfor ~}
%{ if length(peer.export_prefixes) > 0 ~}
route-map EXT-${idx}-OUT permit 10
 match ip address prefix-list EXT-${idx}-OUT
%{ endif ~}
route-map EXT-${idx}-OUT deny 100
!
%{ endfor ~}
router bgp ${bgp_local_as}
 bgp router-id ${bgp_router_id}
 no bgp default ipv4-unicast
 ! Keep eBGP policy enforcement: both kube-vip and external peers have IN/OUT maps.
 bgp ebgp-requires-policy
 bgp network import-check
%{ for peer in bgp_peers ~}
 neighbor ${peer} remote-as ${bgp_local_as}
 neighbor ${peer} update-source ${bgp_router_id}
%{ endfor ~}
 neighbor 127.0.0.1 remote-as ${kube_vip_as}
 neighbor 127.0.0.1 ebgp-multihop
 neighbor 127.0.0.1 update-source 127.0.0.2
 neighbor 127.0.0.1 passive
%{ for peer in external_bgp_peers ~}
 neighbor ${peer.neighbor_ip} remote-as ${peer.neighbor_as}
 neighbor ${peer.neighbor_ip} update-source ${peer.local_ip}
%{ if peer.local_as != bgp_local_as ~}
 neighbor ${peer.neighbor_ip} local-as ${peer.local_as} no-prepend replace-as
%{ endif ~}
%{ endfor ~}
 ! Session commands above are router-level; IPv4 activation/policy is explicit below.
 address-family ipv4 unicast
%{ for vip in advertised_vips ~}
  network ${vip}/32
%{ endfor ~}
%{ if length(redistribute_connected_prefixes) > 0 ~}
  redistribute connected route-map CONNECTED-TO-BGP
%{ endif ~}
%{ for peer in bgp_peers ~}
  neighbor ${peer} activate
  neighbor ${peer} next-hop-self
  neighbor ${peer} route-map IBGP-OUT out
%{ endfor ~}
  neighbor 127.0.0.1 activate
  neighbor 127.0.0.1 route-map KUBE-VIP-IN in
  neighbor 127.0.0.1 route-map KUBE-VIP-OUT out
%{ for idx, peer in external_bgp_peers ~}
  neighbor ${peer.neighbor_ip} activate
  neighbor ${peer.neighbor_ip} route-map EXT-${idx}-IN in
  neighbor ${peer.neighbor_ip} route-map EXT-${idx}-OUT out
%{ endfor ~}
 exit-address-family
!
