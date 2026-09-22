frr version 8.4
frr defaults traditional
hostname ${hostname}
service integrated-vtysh-config
!
router bgp ${ionos_asn}
 bgp router-id ${bgp_router_id}
%{ for peer in gateway_bgp_peers ~}
 neighbor ${peer.wg_address} remote-as ${peer.asn}
 neighbor ${peer.wg_address} update-source ${wireguard_interface}
%{ endfor ~}
 !
 address-family ipv4 unicast
%{ for peer in gateway_bgp_peers ~}
  neighbor ${peer.wg_address} activate
  neighbor ${peer.wg_address} soft-reconfiguration inbound
  neighbor ${peer.wg_address} prefix-list INUYAMA-IN in
  neighbor ${peer.wg_address} prefix-list IONOS-OUT out
%{ endfor ~}
%{ if ionos_network_statements != "" ~}
${ionos_network_statements}
%{ endif ~}
 exit-address-family
!
${inuyama_prefix_list}
${ionos_prefix_list}
!
line vty
!
