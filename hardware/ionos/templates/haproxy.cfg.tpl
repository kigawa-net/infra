global
    log /dev/log local0
    daemon
    maxconn 4096

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client  1h
    timeout server  1h

%{ if inuyama_ingress_vip != "" ~}
frontend http_in
    bind *:80
    mode tcp
    default_backend http_backend

frontend https_in
    bind *:443
    mode tcp
    default_backend https_backend

backend http_backend
    mode tcp
    option tcp-check
    server web1 ${inuyama_ingress_vip}:80 check

backend https_backend
    mode tcp
    option tcp-check
    server web1 ${inuyama_ingress_vip}:443 check

%{ endif ~}
%{ if minecraft_backend_vip != "" ~}
frontend minecraft_in
    bind *:25565
    mode tcp
    default_backend minecraft_backend

backend minecraft_backend
    mode tcp
    option tcp-check
    server mc1 ${minecraft_backend_vip}:25565 check

%{ endif ~}
