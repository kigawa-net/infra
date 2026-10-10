#!/bin/bash
# files/karmada-etcd-member.sh のテスト。偽の etcdctl / etcd / systemctl 等を使い、実機にも etcd にも触れない。
#   bash hardware/modules/karmada-etcd-member/test-karmada-etcd-member.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/files/karmada-etcd-member.sh"
pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok   - $1"; }
ng() { fail=$((fail + 1)); echo "FAIL - $1"; [ -n "${sb:-}" ] && sed 's/^/       | /' "$sb/out" | tail -12; }

# $1: 既存メンバーの一覧(simple 形式)。状態ファイルで、偽の etcdctl の振る舞いを変える:
#   addfail=member add が失敗 / addlost=member add は失敗するが登録は済む / limit=learner 上限のエラー文言
#   startfail=起動に失敗 / neverready=起動はするが、準備ができない / rmfail=member remove が失敗 / padid=ID を空白付きにする
#   unreadable=etcd ユーザーが証明書を読めない
make_sandbox() {
  sb=$(mktemp -d)
  mkdir -p "$sb/bin" "$sb/etc/pki" "$sb/stage" "$sb/data" "$sb/log"
  : > "$sb/log/calls"
  for f in ca.crt tls.crt tls.key; do echo x > "$sb/etc/pki/$f"; done
  printf '%s\n' "$1" > "$sb/list"
  echo "ETCD_NAME=ionos" > "$sb/stage/etcd.env"
  echo "[Unit]" > "$sb/stage/karmada-etcd.service"

  cat > "$sb/bin/etcd" <<EOF
#!/bin/bash
echo "etcd Version: 3.6.8"
EOF

  cat > "$sb/bin/etcdctl" <<EOF
#!/bin/bash
echo "etcdctl \$*" >> "$sb/log/calls"
args="\$*"
id=abcd1234abcd1234
[ -f "$sb/padid" ] && id=" bcd1234abcd1234"
case "\$args" in
  *"endpoint status"*) [ -f "$sb/started" ] && [ ! -f "$sb/neverready" ] && exit 0; exit 1 ;;
  *"member list"*)
    [ -f "$sb/unreachable" ] && exit 1
    cat "$sb/list"
    if [ -f "$sb/registered" ]; then
      if [ -f "$sb/started" ]; then echo "\$id, started, ionos, https://172.31.254.2:2380, https://172.31.254.2:2379, true"
      else echo "\$id, unstarted, , https://172.31.254.2:2380, , true"; fi
    fi ;;
  *"member add"*)
    if [ -f "$sb/limit" ]; then echo "Error: etcdserver: too many learner members in cluster" >&2; exit 1; fi
    if [ -f "$sb/addlost" ]; then touch "$sb/registered"; exit 1; fi
    [ -f "$sb/addfail" ] && exit 1
    touch "$sb/registered"
    echo "Member\$id added to cluster deadbeef"
    echo
    echo 'ETCD_NAME="ionos"'
    echo 'ETCD_INITIAL_CLUSTER="inuyama=https://10.0.0.243:2380,ionos=https://172.31.254.2:2380"'
    echo 'ETCD_INITIAL_CLUSTER_STATE="existing"' ;;
  *"member remove"*)
    [ -f "$sb/rmfail" ] && exit 1
    # 本物と同じく、ID は 16 進数だけ(空白や余計な文字が付いていたら、失敗する)
    rid="\${args##* }"
    [[ "\$rid" =~ ^[0-9a-f]+\$ ]] || { echo "Error: invalid member ID \$rid" >&2; exit 1; }
    rm -f "$sb/registered" "$sb/started"; echo removed ;;
esac
exit 0
EOF

  cat > "$sb/bin/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$sb/log/calls"
case "\$*" in
  "is-active karmada-etcd")
    [ -f "$sb/sysfail" ] && exit 4   # systemd と通信できない(何も出力しない)
    if [ -f "$sb/active" ]; then echo active; exit 0; else echo inactive; exit 3; fi ;;
  "enable --now karmada-etcd"|"start karmada-etcd")
    [ -f "$sb/startfail" ] && exit 1
    touch "$sb/active"; mkdir -p "$sb/data/member"
    [ -f "$sb/registered" ] && touch "$sb/started"
    [ -f "$sb/sysfail_after_start" ] && touch "$sb/sysfail"
    exit 0 ;;
  "stop karmada-etcd") [ -f "$sb/sysfail" ] && exit 1; rm -f "$sb/active"; exit 0 ;;
  *) exit 0 ;;
esac
EOF

  printf '#!/bin/bash\necho "useradd $*" >> "%s/log/calls"\nexit 0\n' "$sb" > "$sb/bin/useradd"
  # etcd ユーザーは、あることにする
  printf '#!/bin/bash\ncase "$1" in etcd) exit 0;; *) exec /usr/bin/id "$@";; esac\n' > "$sb/bin/id"
  # runuser: 読めない設定なら、test -r を失敗させる
  cat > "$sb/bin/runuser" <<EOF
#!/bin/bash
[ -f "$sb/unreadable" ] && exit 1
exit 0
EOF
  chmod +x "$sb/bin/"*
}

run() {
  env PATH="$sb/bin:$PATH" ALLOW_NON_ROOT=1 SKIP_CERT_CHECK=1 JOIN="${JOIN:-1}" \
    STAGE_DIR="$sb/stage" ETC_DIR="$sb/etc" BIN_DIR="$sb/bin" DATA_DIR="$sb/data" UNIT_PATH="$sb/karmada-etcd.service" \
    SYSTEMCTL="$sb/bin/systemctl" ETCDCTL="$sb/bin/etcdctl" WAIT_SECONDS=6 \
    MEMBER_NAME=ionos PEER_URL=https://172.31.254.2:2380 SEED_ENDPOINTS=https://10.0.0.243:2379 \
    ETCD_VERSION=3.6.8 TARBALL_SHA256=00 CERT_IP=172.31.254.2 \
    bash "$script" > "$sb/out" 2>&1
  rc=$?
}
called() { grep -q -- "$1" "$sb/log/calls"; }

LIST_OK='7f4f005e7c3b950d, started, inuyama, https://10.0.0.243:2380, https://10.0.0.243:2379, false
fdc77b47016dd7e6, started, soichiro, https://10.255.10.12:2380, https://10.255.10.12:2379, true'
fresh() { make_sandbox "${1:-$LIST_OK}"; rm -rf "$sb/data/member"; }

# 1. 新規参加
fresh; run
[ $rc -eq 0 ] && called "member add ionos --learner --peer-urls=https://172.31.254.2:2380" && ok "新規: learner として member add する" || ng "新規: member add (rc=$rc)"
[ "$(grep -c '^ETCD_INITIAL_CLUSTER=' "$sb/etc/etcd.env")" = 1 ] && ok "新規: ETCD_INITIAL_CLUSTER が env に 1 つだけ入る" || ng "新規: INITIAL_CLUSTER の数"
called "enable --now karmada-etcd" && ok "新規: etcd を起動する" || ng "新規: 起動しない"
called "promote" && ng "新規: promote を呼んでいる(してはいけない)" || ok "新規: promote は呼ばない"

# 2. JOIN=0: 用意だけ。参加も起動もしない
fresh; JOIN=0 run
if [ $rc -eq 0 ] && ! called "member add" && ! called "enable --now" && [ -s "$sb/karmada-etcd.service" ]; then ok "JOIN=0: 用意だけで、参加も起動もしない"; else ng "JOIN=0 (rc=$rc)"; fi

# 3. 参加済み(データあり・起動済み): member add しない、準備を確認する
make_sandbox "$LIST_OK"; touch "$sb/registered" "$sb/started" "$sb/active"; mkdir -p "$sb/data/member"; run
if [ $rc -eq 0 ] && ! called "member add"; then ok "参加済み: member add しない"; else ng "参加済み (rc=$rc)"; fi

# 4. 参加済みで env を作り直しても、INITIAL_CLUSTER を保つ(1 つだけ)
fresh; run
echo "ETCD_NAME=ionos2" > "$sb/stage/etcd.env"; run
if [ "$(grep -c '^ETCD_INITIAL_CLUSTER=' "$sb/etc/etcd.env")" = 1 ] && grep -q '^ETCD_NAME=ionos2' "$sb/etc/etcd.env"; then ok "再実行: INITIAL_CLUSTER を 1 つ保って env を更新する"; else ng "再実行: INITIAL_CLUSTER"; fi

# 5. 同じ名前が登録済み(started)で、データが無い: 中止。member add も remove もしない
fresh "$LIST_OK
bbbb, started, ionos, https://172.31.254.2:2380, https://172.31.254.2:2379, true"; run
if [ $rc -ne 0 ] && ! called "member add" && ! called "member remove"; then ok "登録済み(started): 中止し、何も変えない"; else ng "登録済み(started) (rc=$rc)"; fi

# 6. 前回の失敗の残り(unstarted の learner): 外してから、やり直す
fresh "$LIST_OK"; touch "$sb/registered"; run
if [ $rc -eq 0 ] && called "member remove" && called "member add"; then ok "残骸(unstarted の learner): 外してやり直す"; else ng "残骸 (rc=$rc)"; fi

# 7. voter が無い: 参加させない
fresh "fdc77b47016dd7e6, started, soichiro, https://10.255.10.12:2380, https://10.255.10.12:2379, true"; run
[ $rc -ne 0 ] && ! called "member add" && ok "voter 無し: 参加させない" || ng "voter 無し (rc=$rc)"

# 8. 起動の失敗: 登録を取り消し(ID は完全一致)、登録が実際に消え、データも消える
fresh; touch "$sb/startfail"; run
if [ $rc -ne 0 ] && called "member remove abcd1234abcd1234$" && [ ! -f "$sb/registered" ] && [ ! -d "$sb/data/member" ]; then ok "起動失敗: 登録を取り消す"; else ng "起動失敗 (rc=$rc)"; fi

# 9. ID が空白付きでも、取り消せる(Codex 指摘)。偽の member remove は、空白付き・余計な文字付きの ID を拒否する
fresh; touch "$sb/startfail" "$sb/padid"; run
if [ $rc -ne 0 ] && called "member remove bcd1234abcd1234$" && [ ! -f "$sb/registered" ]; then ok "空白付き ID: 空白を除いて取り消す(登録が消える)"; else ng "空白付き ID (rc=$rc)"; fi

# 9b. 空白付き ID の残骸(unstarted の learner)も、再実行で外してやり直せる(Codex 指摘)
fresh; touch "$sb/registered" "$sb/padid"; run
if [ $rc -eq 0 ] && called "member remove bcd1234abcd1234$" && called "member add"; then ok "空白付き ID の残骸: 外してやり直す"; else ng "空白付き ID の残骸 (rc=$rc)"; fi

# 9c. 停止を確認できない(systemd と通信できない): データを消さず、member remove もしない(Codex 指摘)
fresh; touch "$sb/neverready" "$sb/sysfail_after_start"; run
if [ $rc -ne 0 ] && [ -d "$sb/data/member" ] && ! called "member remove" && grep -q "停止を確認できませんでした" "$sb/out"; then ok "停止を確認できない: データを残し、remove もしない"; else ng "停止を確認できない (rc=$rc)"; fi

# 10. 取り消しに失敗: データを消さない(Codex 指摘)
fresh; touch "$sb/neverready" "$sb/rmfail"; run   # 準備できない → ロールバック → remove が失敗
if [ $rc -ne 0 ] && [ -d "$sb/data/member" ] && grep -q "手動で: etcdctl member remove" "$sb/out"; then ok "取り消し失敗: データを残し、手順を表示する"; else ng "取り消し失敗 (rc=$rc)"; fi

# 11. 準備できない(一覧には載るが、このホストの etcd が応答しない): 取り消す
fresh; touch "$sb/neverready"; run
if [ $rc -ne 0 ] && called "member remove"; then ok "準備できない: 登録を取り消す"; else ng "準備できない (rc=$rc)"; fi

# 12. learner の上限: 登録されず、起動しない。理由を表示する
fresh; touch "$sb/limit"; run
if [ $rc -ne 0 ] && ! called "enable --now" && ! called "member remove" && grep -q "max-learners" "$sb/out"; then ok "learner 上限: 起動せず、理由を表示する"; else ng "learner 上限 (rc=$rc)"; fi

# 13. member add の応答だけ失われ、登録は済んでいる: 取り消す(Codex 指摘)
fresh; touch "$sb/addlost"; run
if [ $rc -ne 0 ] && called "member remove"; then ok "応答喪失: 登録を取り消す"; else ng "応答喪失 (rc=$rc)"; fi

# 14. 証明書が無い / etcd ユーザーが読めない: 登録の前に中止する
fresh; rm -f "$sb/etc/pki/tls.key"; run
[ $rc -ne 0 ] && ! called "member add" && ok "証明書無し: 中止する" || ng "証明書無し (rc=$rc)"
fresh; touch "$sb/unreadable"; run
[ $rc -ne 0 ] && ! called "member add" && ok "etcd ユーザーが読めない: 登録の前に中止する" || ng "etcd ユーザーが読めない (rc=$rc)"

# 14b. JOIN=0 の再 apply: 稼働中の etcd を、start / stop / restart しない(設定が変わっても)
make_sandbox "$LIST_OK"; touch "$sb/registered" "$sb/started" "$sb/active"; mkdir -p "$sb/data/member"
JOIN=0 run; echo "ETCD_NAME=changed" > "$sb/stage/etcd.env"; : > "$sb/log/calls"; JOIN=0 run
if [ $rc -eq 0 ] && ! called "start " && ! called "stop " && ! called "restart" && ! called "enable --now" && ! called "member "; then ok "JOIN=0 の再 apply: 稼働中の etcd に触れない"; else ng "JOIN=0 の再 apply (rc=$rc)"; fi

# 15. 既存のメンバーに接続できない: 中止する
fresh; touch "$sb/unreachable"; run
[ $rc -ne 0 ] && ! called "member add" && ok "接続不可: 中止する" || ng "接続不可 (rc=$rc)"

echo "--- $pass passed, $fail failed"
[ "$fail" = 0 ]
