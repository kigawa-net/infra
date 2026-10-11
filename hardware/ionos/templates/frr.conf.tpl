frr version 8.4
frr defaults traditional
hostname ${hostname}
service integrated-vtysh-config
!
router bgp ${ionos_asn}
 bgp router-id ${bgp_router_id}
%{ for peer in gateway_bgp_peers ~}
 neighbor ${peer.wg_address} remote-as ${peer.asn}
 neighbor ${peer.wg_address} update-source ${peer.interface}
%{ if peer.fast_timers ~}
 neighbor ${peer.wg_address} timers 3 9
%{ endif ~}
%{ endfor ~}
 !
 address-family ipv4 unicast
%{ for peer in gateway_bgp_peers ~}
  neighbor ${peer.wg_address} activate
  neighbor ${peer.wg_address} soft-reconfiguration inbound
  neighbor ${peer.wg_address} prefix-list ${peer.in_list} in
%{ if peer.local_pref > 0 ~}
  neighbor ${peer.wg_address} route-map LP${peer.local_pref} in
%{ endif ~}
  neighbor ${peer.wg_address} prefix-list ${peer.out_list} out
%{ endfor ~}
%{ if ionos_network_statements != "" ~}
${ionos_network_statements}
%{ endif ~}
 exit-address-family
!
${inuyama_prefix_list}
${ionos_prefix_list}
%{ if soichiro_prefix_list != "" ~}
${soichiro_prefix_list}
%{ endif ~}
!
%{ for lp in local_prefs ~}
route-map LP${lp} permit 10
 set local-preference ${lp}
exit
!
%{ endfor ~}
! BGP で学んだ経路を、カーネルに入れるとき、送信元アドレスを、IONOS の wg0 のアドレスに固定する。
! 切り替え(wg0 のカーネルの経路の削除)で、IONOS 発の通信(etcd #3、HAProxy → 10.0.0.240/241、IONOS の Karmada apiserver →
! Inuyama)が、専用リンク(wg-gw4 / wg-gw2)から出るようになっても、送信元が、今までと同じ ${local_src} になる(固定しないと、
! 専用リンクの主アドレス 172.31.252.x になり、Inuyama の各ノードに戻りの経路がなく、返信が届かない)。
ip protocol bgp route-map SET-SRC
!
route-map SET-SRC permit 10
 set src ${local_src}
exit
!
line vty
!
