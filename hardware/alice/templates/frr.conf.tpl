frr version 8.4
frr defaults traditional
hostname ${hostname}
service integrated-vtysh-config
!
router bgp ${alice_asn}
 bgp router-id ${bgp_router_id}
 neighbor ${inuyama_wg_address} remote-as ${inuyama_asn}
 neighbor ${inuyama_wg_address} update-source ${wireguard_interface}
 !
 address-family ipv4 unicast
  neighbor ${inuyama_wg_address} activate
  neighbor ${inuyama_wg_address} soft-reconfiguration inbound
  neighbor ${inuyama_wg_address} prefix-list INUYAMA-IN in
  neighbor ${inuyama_wg_address} prefix-list ALICE-OUT out
%{ if alice_network_statements != "" ~}
${alice_network_statements}
%{ endif ~}
 exit-address-family
!
${inuyama_prefix_list}
${alice_prefix_list}
!
line vty
!
