frr defaults traditional
log syslog informational
service integrated-vtysh-config
!
! 受け取る経路は、完全一致の prefix だけ(ge / le を付けない)。それ以外は、deny 100 で捨てる。
%{ for idx, prefix in import_prefixes ~}
ip prefix-list OVERLAY-IN seq ${(idx + 1) * 10} permit ${prefix}
%{ endfor ~}
%{ if length(import_prefixes) > 0 ~}
route-map OVERLAY-IN permit 10
 match ip address prefix-list OVERLAY-IN
%{ endif ~}
route-map OVERLAY-IN deny 100
!
router bgp ${local_as}
 bgp router-id ${router_id}
 no bgp default ipv4-unicast
 ! out の route-map を置かない(ebgp-requires-policy により、何も広告しない)。overlay の IP は connected で、相手は既に知っている。
 bgp ebgp-requires-policy
%{ for n in neighbors ~}
 neighbor ${n} remote-as ${remote_as}
 neighbor ${n} update-source ${router_id}
%{ endfor ~}
 address-family ipv4 unicast
%{ for n in neighbors ~}
  neighbor ${n} activate
  neighbor ${n} route-map OVERLAY-IN in
%{ endfor ~}
 exit-address-family
!
