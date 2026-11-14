#!/bin/bash
# EasyTier 2.6.4 の Secure Mode と credential の挙動を、手元(loopback、TUN なし)で確かめる実験。本番には触れない。
# docs/easytier-secure-mode-rollout.md の「検証済みの事実」の根拠。EasyTier を上げるときは、これを再実行して、結果が変わらないか確認すること。
# 必要: curl、unzip、sha256sum(リリースを GitHub から取得し、sha256 を検証する)。所要: 約 2 分。
# 使い方: bash hardware/modules/easytier/experiment-secure-mode.sh
set -u
VERSION=2.6.4
SHA256=61b659eaedba658fa66fe47d17e1426cdd77e5d02fa15fed447bb4357c09dfd6   # hardware/k8s4/variables.tf の easytier_sha256 と同じ値
D=$(mktemp -d); trap 'cleanup; rm -rf "$D"' EXIT
cd "$D"
curl -fsSL -o et.zip "https://github.com/EasyTier/EasyTier/releases/download/v${VERSION}/easytier-linux-x86_64-v${VERSION}.zip"
echo "${SHA256}  et.zip" | sha256sum -c - >/dev/null || { echo "sha256 が一致しません"; exit 1; }
unzip -q et.zip
CORE=$(find . -name easytier-core -type f | head -1); CLI=$(find . -name easytier-cli -type f | head -1); chmod +x "$CORE" "$CLI"
SECRET=experiment-secret
pids=(); cleanup() { for p in "${pids[@]:-}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; pids=(); }
NET=exp-$$

# start <name> <rpc-port> <listen-port> <peer-uri|""> [core options...]
# --bind-device false: 外向きソケットを物理 NIC に縛らない(縛ると、loopback の peer に届かない)
start() {
  local name=$1 rpc=$2 lp=$3 peer=$4; shift 4
  local args=(--hostname "$name" --network-name "$NET" --no-tun -i "10.99.$((rpc % 200)).1" --bind-device false --rpc-portal "127.0.0.1:$rpc" --listeners "tcp://127.0.0.1:$lp")
  [ -n "$peer" ] && args+=(--peers "$peer")
  "$CORE" "${args[@]}" "$@" > "log-$name.txt" 2>&1 &
  pids+=($!); echo $! > "pid-$name"
}
peers_of() { "$CLI" -p "127.0.0.1:$1" peer 2>&1 | awk -F'|' 'NR>2{gsub(/ /,"",$3); printf "%s ", $3}'; echo; }
gen() { "$CLI" -p "127.0.0.1:$1" credential generate "${@:2}" 2>&1 | grep -o -E 'credential_secret: +[A-Za-z0-9+/=]+' | awk '{print $2}'; }
pass=0; fail=0
expect() { # <説明> <peers の出力> <含むべき名前> <含まない名前>
  local desc=$1 out=$2 want=$3 unwant=${4:-}
  if [[ " $out" == *" $want "* || " $out" == *" $want" ]] && { [ -z "$unwant" ] || [[ " $out" != *" $unwant "* ]]; }; then echo "  OK  : $desc ($out)"; pass=$((pass+1)); else echo "  FAIL: $desc ($out)"; fail=$((fail+1)); fi
}
expect_absent() { local desc=$1 out=$2 name=$3; if [[ " $out" != *" $name "* && " $out" != *" $name" ]]; then echo "  OK  : $desc ($out)"; pass=$((pass+1)); else echo "  FAIL: $desc ($out)"; fail=$((fail+1)); fi; }

echo "E1: secure と secure(network_secret あり)は、credential なしで接続できる"
start A1 21881 21011 "" --network-secret $SECRET --secure-mode true
start B1 21882 21012 tcp://127.0.0.1:21011 --network-secret $SECRET --secure-mode true
sleep 7; expect "A が B1 を見る" "$(peers_of 21881)" B1; cleanup

echo "E2: secure のノードに、非 secure のノードは接続できない(#503 の障害)"
start A2 21883 21013 "" --network-secret $SECRET --secure-mode true
start B2 21884 21014 tcp://127.0.0.1:21013 --network-secret $SECRET
sleep 7; expect_absent "A が B2 を見ない" "$(peers_of 21883)" B2; cleanup

echo "E3: 非 secure のノードに、secure のノードは接続できない(逆向きも同じ)"
start A3 21885 21015 "" --network-secret $SECRET
start B3 21886 21016 tcp://127.0.0.1:21015 --network-secret $SECRET --secure-mode true
sleep 7; expect_absent "A が B3 を見ない" "$(peers_of 21885)" B3; cleanup

echo "E4/E5/E6/E7: credential で、network_secret なしで参加できる。revoke で切れる。違う secret は拒否。正しい secret があれば、credential なしでも参加できる(secure mode は、secret の漏洩を防がない)"
rm -f cred4.json
start ADM 21891 21041 "" --network-secret $SECRET --secure-mode true --credential-file "$PWD/cred4.json"
sleep 4
C=$(gen 21891 --ttl 600 --credential-id edge1 --reusable false)
start EDGE 21892 21042 tcp://127.0.0.1:21041 --credential "$C"
sleep 7; expect "credential だけの EDGE が参加できる" "$(peers_of 21891)" EDGE
"$CLI" -p 127.0.0.1:21891 credential revoke edge1 >/dev/null 2>&1; sleep 6
expect_absent "revoke すると EDGE が切れる" "$(peers_of 21891)" EDGE
start BAD 21893 21043 tcp://127.0.0.1:21041 --network-secret wrong --secure-mode true
start LEAK 21894 21044 tcp://127.0.0.1:21041 --network-secret $SECRET --secure-mode true
sleep 7; out=$(peers_of 21891)
expect_absent "違う secret は拒否される" "$out" BAD
expect "正しい secret は、credential なしで参加できる(漏洩したら、参加される)" "$out" LEAK
cleanup

echo "E8: 10 年の TTL を受け付け、admin を再起動しても、credential が残る"
rm -f cred8.json
start ADM 21951 21061 "" --network-secret $SECRET --secure-mode true --credential-file "$PWD/cred8.json"
sleep 4; C=$(gen 21951 --ttl 315360000 --credential-id long --reusable true)
kill "$(cat pid-ADM)"; sleep 2
start ADM 21951 21061 "" --network-secret $SECRET --secure-mode true --credential-file "$PWD/cred8.json"
sleep 4; start EDGE 21952 21062 tcp://127.0.0.1:21061 --credential "$C"
sleep 7; expect "再起動後も、同じ credential で参加できる" "$(peers_of 21951)" EDGE; cleanup

echo "E9: credential のノードは、別の credential のノード(--allow-relay でも)を経由して参加できない。ハブは network_secret のノードにすること"
rm -f cred9.json
start ADM 21961 21071 "" --network-secret $SECRET --secure-mode true --credential-file "$PWD/cred9.json"
sleep 4; CR=$(gen 21961 --ttl 3600 --credential-id relay --allow-relay); CK=$(gen 21961 --ttl 3600 --credential-id k1)
start RL 21962 21072 tcp://127.0.0.1:21071 --credential "$CR"
start K1 21963 21073 tcp://127.0.0.1:21072 --credential "$CK"
sleep 8; expect_absent "K1 は、credential の RL 経由では、ADM を見ない" "$(peers_of 21963)" ADM; cleanup

echo "E10/E11/E12/E13/E15: ハブが 2 台(network_secret)あれば、片方が落ちても、credential のノードは残り、再起動もでき、ノード同士も見える"
rm -f cred10.json
start H1 21971 21081 "" --network-secret $SECRET --secure-mode true --credential-file "$PWD/cred10.json"
start H2 21972 21082 tcp://127.0.0.1:21081 --network-secret $SECRET --secure-mode true
sleep 5; C1=$(gen 21971 --ttl 86400 --credential-id k1 --reusable true); C2=$(gen 21971 --ttl 86400 --credential-id k2 --reusable true)
start K1 21973 21083 tcp://127.0.0.1:21082 --credential "$C1"
start K2 21974 21084 tcp://127.0.0.1:21082 --credential "$C2"
sleep 9; expect "K1 が、H2 だけを peer にして参加し、K2 も見える" "$(peers_of 21973)" K2
kill "$(cat pid-H1)"; sleep 10
expect "H1 が落ちても、K1 は H2 に残る" "$(peers_of 21973)" H2
kill "$(cat pid-K1)"; sleep 2; start K1 21973 21083 tcp://127.0.0.1:21082 --credential "$C1"
sleep 9; expect "H1 が落ちている間に、K1 を再起動できる" "$(peers_of 21973)" H2
cleanup
echo
echo "結果: OK=$pass FAIL=$fail"
[ "$fail" = 0 ]
