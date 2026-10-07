#!/usr/bin/env bash
# kube-vip-health.sh のオフラインテスト。偽の curl / ip / logger を使うので、実機には触れない。
# 使い方: bash hardware/modules/kube-vip/test-kube-vip-health.sh
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/files/kube-vip-health.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
check() { # 名前 期待 実際
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected=$2 actual=$3)"; fails=$((fails + 1)); fi
}

# 偽コマンド: curl は、URL が 127.0.0.1 なら local_code、それ以外(ピア)なら peer_code を返す。
# ip は $work/vip_present があると VIP を表示し、addr del で消す。
cat > "$work/curl" <<'EOF'
#!/usr/bin/env bash
url="${@: -1}"
echo "$url" >> "$FAKE_DIR/curl_urls"
case "$url" in
  *127.0.0.1*) cat "$FAKE_DIR/local_code" ;;
  *) cat "$FAKE_DIR/peer_code" ;;
esac
EOF
cat > "$work/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"addr show"*) [ -f "$FAKE_DIR/vip_present" ] && echo "    inet 10.0.0.100/32 scope global ens18" ;;
  *"addr del"*) rm -f "$FAKE_DIR/vip_present"; echo "$*" >> "$FAKE_DIR/ip_del.log" ;;
esac
exit 0
EOF
cat > "$work/logger" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DIR/log"
EOF
chmod +x "$work/curl" "$work/ip" "$work/logger"

export FAKE_DIR="$work" STATE_DIR="$work/state" MANIFEST="$work/kube-vip.yaml" VIP=10.0.0.100 IFACE=ens18
export CURL_BIN="$work/curl" IP_BIN="$work/ip" LOGGER_BIN="$work/logger"
export FAIL_THRESHOLD=3 OK_THRESHOLD=4 PEERS="10.0.0.120 10.0.0.140" ENABLED=true

run() { bash "$script"; }
set_local() { printf '%s' "$1" > "$work/local_code"; }
set_peer() { printf '%s' "$1" > "$work/peer_code"; }
reset() {
  rm -rf "$work/state" "$work/ip_del.log" "$work/log" "$work/vip_present" "$work/curl_urls"
  echo "apiVersion: v1" > "$MANIFEST"; set_local 200; set_peer 200
  export PEERS="10.0.0.120 10.0.0.140" ENABLED=true
}
manifest() { [ -f "$MANIFEST" ] && echo yes || echo no; }
parked() { [ -f "$STATE_DIR/kube-vip.yaml" ] && echo yes || echo no; }

# 1. 健全なら何もしない
reset
run; run; run
check "healthy: manifest stays" "yes" "$(manifest)"

# 2. 失敗が閾値未満なら退避しない
reset; set_local 000
run; run
check "2 fails < threshold: manifest stays" "yes" "$(manifest)"

# 3. 途中で成功したら失敗の連続がリセットされる
set_local 200; run; set_local 000; run; run
check "fail streak resets after success: manifest stays" "yes" "$(manifest)"

# 4. 閾値に達し、ピアが健全なら退避する(HTTP 500 も失敗)
reset; set_local 500
run; run; run
check "3 consecutive fails + healthy peer: manifest parked" "no" "$(manifest)"
check "parked copy exists" "yes" "$(parked)"

# 5. 退避中、VIP が残っていれば外す
touch "$work/vip_present"
run
check "leftover VIP removed while parked" "no" "$([ -f "$work/vip_present" ] && echo yes || echo no)"
check "ip addr del called with VIP/32" "yes" "$(grep -q 'addr del 10.0.0.100/32 dev ens18' "$work/ip_del.log" 2>/dev/null && echo yes || echo no)"

# 6. 退避中に失敗が続く間は戻さない
run; run; run; run; run
check "still failing: stays parked" "no" "$(manifest)"

# 7. 回復しても、OK が閾値未満なら戻さない。途中の失敗でカウントが戻る
set_local 200; run; run; run
check "3 oks < threshold: stays parked" "no" "$(manifest)"
set_local 000; run
set_local 200; run; run; run
check "ok streak reset by a failure: stays parked" "no" "$(manifest)"

# 8. OK が閾値に達したら戻す
run
check "4 consecutive oks: manifest restored" "yes" "$(manifest)"
check "parked copy consumed" "no" "$(parked)"

# 9. マニフェストが無い(退避もしていない)ときは何もしない
rm -rf "$STATE_DIR" "$MANIFEST"; set_local 000
run; run; run; run
check "no manifest, not parked: no-op" "no" "$(parked)"

# 10. ローカルの確認は etcd を除外した livez
reset; run
check "uses /livez?exclude=etcd" "yes" "$(grep -q '127.0.0.1:6443/livez?exclude=etcd' "$work/curl_urls" && echo yes || echo no)"

# 11. 全滅の保護: ピアが全て不健全なら、ローカルが失敗し続けても退避しない
reset; set_local 000; set_peer 000
run; run; run; run; run; run
check "no healthy peer: manifest stays (no cluster-wide park)" "yes" "$(manifest)"
check "no healthy peer: not parked" "no" "$(parked)"
check "logs the refusal" "yes" "$(grep -q 'no healthy peer' "$work/log" && echo yes || echo no)"
# ピアが回復したら退避する
set_peer 200; run
check "peer recovers: now parks" "no" "$(manifest)"

# 12. ピアが未設定なら、退避しない(安全側)
reset; export PEERS=""; set_local 000
run; run; run; run
check "PEERS empty: never parks" "yes" "$(manifest)"

# 13. 1 つでもピアが健全なら退避する(片方が不健全でもよい)
reset; set_local 000
cat > "$work/curl" <<'EOF'
#!/usr/bin/env bash
url="${@: -1}"
case "$url" in
  *127.0.0.1*) cat "$FAKE_DIR/local_code" ;;
  *10.0.0.140*) printf 200 ;;
  *) printf 000 ;;
esac
EOF
run; run; run
check "one healthy peer among two: parks" "no" "$(manifest)"

# 14. ENABLED=false(Terraform が kube-vip を意図的に外したノード)では、退避中のコピーを戻さない
reset; mkdir -p "$STATE_DIR"; echo "old" > "$STATE_DIR/kube-vip.yaml"; rm -f "$MANIFEST"
export ENABLED=false; set_local 200
run; run; run; run; run; run
check "ENABLED=false: parked copy not restored" "no" "$(manifest)"
check "ENABLED=false: parked copy untouched" "yes" "$(parked)"

# 15. ENABLED=false では、ローカルが失敗しても何もしない
reset; export ENABLED=false; set_local 000
run; run; run; run
check "ENABLED=false: never parks" "yes" "$(manifest)"

# 16. Terraform が新しいマニフェストを書いた後に、古い退避コピーがあっても上書きしない
reset; mkdir -p "$STATE_DIR"; echo "old" > "$STATE_DIR/kube-vip.yaml"; echo "new" > "$MANIFEST"; set_local 200
run; run; run; run; run; run
check "active manifest not overwritten by stale parked copy" "new" "$(cat "$MANIFEST")"

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
