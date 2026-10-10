#!/bin/bash
# files/karmada-cp-member.sh と files/karmada-cp-redirect.sh のテスト。
# 偽の systemctl / curl / crane / iptables / ufw を使い、実機にも、クラスターにも触れない。証明書は、使い捨ての CA で作る。
#   bash hardware/modules/karmada-cp-member/test-karmada-cp-member.sh
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MEMBER="$here/files/karmada-cp-member.sh"
REDIR="$here/files/karmada-cp-redirect.sh"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   - $1"; }
ng() { fail=$((fail + 1)); echo "FAIL - $1"; [ -f "${sb:-/nonexistent}/out" ] && tail -5 "$sb/out" | sed 's/^/       | /'; }
chk() { # $1=名前 $2=条件(終了コード 0 で成功)。サブシェルで評価する(条件の中の exit が、テスト全体を終わらせないように)
  if ( eval "$2" ); then ok "$1"; else ng "$1"; fi
}

ALL="karmada-aggregated-apiserver karmada-apiserver karmada-controller-manager karmada-metrics-adapter karmada-scheduler karmada-webhook"
ADV=172.31.254.2

# ---- サンドボックス ----
mksb() {
  sb=$(mktemp -d)
  mkdir -p "$sb/bin" "$sb/etc" "$sb/sbin" "$sb/bindir" "$sb/sysd" "$sb/stage" "$sb/serve" "$sb/sys" "$sb/ca"
  : > "$sb/calls"
  printf '127.0.0.1 localhost\n10.0.0.5 other-host\n' > "$sb/hosts"
  printf 'MemAvailable:    2000000 kB\n' > "$sb/meminfo"

  # 偽のコマンド
  cat > "$sb/bin/id" <<EOF
#!/bin/bash
case "\$1" in karmada) exit 0;; *) exec /usr/bin/id "\$@";; esac
EOF
  printf '#!/bin/bash\necho "useradd $*" >> "%s/calls"\n' "$sb" > "$sb/bin/useradd"
  cat > "$sb/bin/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$sb/calls"
args=("\$@"); cmd=\${args[0]}; unit=""
for a in "\${args[@]:1}"; do case "\$a" in --*) ;; *) unit=\$a;; esac; done
u=\${unit%.service}
case "\$cmd" in
  daemon-reload) exit 0 ;;
  enable)
    touch "$sb/sys/enabled-\$u"
    case " \${args[*]} " in *" --now "*)
      [ -f "$sb/failstart-\$u" ] && exit 1
      touch "$sb/sys/active-\$u"
      # REDIRECT のユニットは、ExecStart でルールを入れる(RemainAfterExit)
      [ "\$u" = karmada-cp-redirect ] && [ ! -f "$sb/sys/ran-\$u" ] && { touch "$sb/sys/ran-\$u"; IPTABLES="$sb/bin/iptables" REDIRECT_TABLE="$sb/etc/redirect.table" bash "$sb/sbin/karmada-cp-redirect.sh" start; } ;; esac
    exit 0 ;;
  disable) rm -f "$sb/sys/enabled-\$u"; exit 0 ;;
  stop) rm -f "$sb/sys/active-\$u"; exit 0 ;;
  restart) [ -f "$sb/failstart-\$u" ] && exit 1; touch "$sb/sys/active-\$u"; exit 0 ;;
  is-active) [ -f "$sb/crash-\$u" ] && [ -f "$sb/sys/crashed-\$u" ] && exit 3
             if [ -f "$sb/sys/active-\$u" ]; then
               [ -f "$sb/crash-\$u" ] && touch "$sb/sys/crashed-\$u"   # 起動して、2 回目の確認で、落ちている(再起動の繰り返し)
               exit 0
             fi
             exit 3 ;;
  is-enabled) [ -f "$sb/sys/enabled-\$u" ] && exit 0 || exit 1 ;;
esac
exit 0
EOF
  cat > "$sb/bin/curl" <<EOF
#!/bin/bash
echo "curl \$*" >> "$sb/calls"
out=""; url=""; prev=""
for a in "\$@"; do
  [ "\$prev" = "-o" ] && out=\$a
  case "\$a" in http*) url=\$a;; esac
  prev=\$a
done
case "\$url" in
  */readyz) [ -f "$sb/readyz_fail" ] && exit 22; exit 0 ;;
esac
f="$sb/serve/\$(basename "\$url")"
[ -f "\$f" ] || exit 22
cp "\$f" "\$out"
EOF
  cat > "$sb/bin/crane" <<EOF
#!/bin/bash
# 偽の crane(使わない。本物は、tarball の中の crane)
exit 1
EOF
  cat > "$sb/bin/iptables" <<EOF
#!/bin/bash
echo "iptables \$*" >> "$sb/calls"
shift 2   # -t nat
act=\$1; shift; shift   # -C/-A/-D OUTPUT
rule="\$*"
case "\$act" in
  -C) grep -qxF -- "\$rule" "$sb/ipt" 2>/dev/null ;;
  -A) echo "\$rule" >> "$sb/ipt" ;;
  -D) grep -vxF -- "\$rule" "$sb/ipt" > "$sb/ipt.new"; mv "$sb/ipt.new" "$sb/ipt" ;;
esac
EOF
  printf '#!/bin/bash\necho "ufw $*" >> "%s/calls"\n' "$sb" > "$sb/bin/ufw"
  printf '#!/bin/bash\necho "journal: $*"\n' > "$sb/bin/journalctl"
  chmod +x "$sb/bin/"*
  : > "$sb/ipt"

  # 偽のバイナリと、取得元の模擬
  : > "$sb/binaries.txt"
  for n in kube-apiserver karmada-controller-manager karmada-scheduler karmada-webhook karmada-aggregated-apiserver karmada-metrics-adapter; do
    printf '#!/bin/sh\necho %s\n' "$n" > "$sb/serve/real-$n"
    sha=$(sha256sum "$sb/serve/real-$n" | cut -d' ' -f1)
    if [ "$n" = kube-apiserver ]; then
      cp "$sb/serve/real-$n" "$sb/serve/$n"
      echo "$n|url|https://dl.test/$n||$sha" >> "$sb/binaries.txt"
    else
      mkdir -p "$sb/img-$n/bin"; cp "$sb/serve/real-$n" "$sb/img-$n/bin/$n"
      echo "$n|image|reg.test/karmada/$n@sha256:abc|bin/$n|$sha" >> "$sb/binaries.txt"
    fi
  done
  # 偽の crane の tarball(中身は、image ごとの tar を出す shell)
  mkdir -p "$sb/cranepkg"
  cat > "$sb/cranepkg/crane" <<EOF
#!/bin/bash
echo "crane \$*" >> "$sb/calls"
[ "\$1" = export ] || exit 2
n=\$(basename "\${2%%@*}")
tar -c -C "$sb/img-\$n" bin/\$n
EOF
  chmod +x "$sb/cranepkg/crane"
  tar czf "$sb/serve/crane.tgz" -C "$sb/cranepkg" crane
  echo "https://crane.test/crane.tgz|$(sha256sum "$sb/serve/crane.tgz" | cut -d' ' -f1)" > "$sb/stage/crane.txt"
  cp "$sb/binaries.txt" "$sb/stage/binaries.txt"

  # bundle / スクリプト
  cp "$REDIR" "$sb/stage/karmada-cp-redirect.sh"
  mkbundle
}

mkbundle() {
  {
    printf '@@@ /etc/systemd/system/karmada-cp.slice 0644\n[Slice]\nMemoryMax=800M\n'
    printf '@@@ /etc/systemd/system/karmada-cp-redirect.service 0644\n[Service]\nType=oneshot\n'
    printf '@@@ /etc/karmada/redirect.table 0644\n127.0.0.11 8443\n127.0.0.12 7443\n127.0.0.13 7444\n'
    printf '@@@ /etc/karmada/hosts.block 0644\n127.0.0.11  karmada-webhook.karmada-system.svc\n127.0.0.12  karmada-aggregated-apiserver.karmada-system.svc\n127.0.0.13  karmada-metrics-adapter.karmada-system.svc\n'
    printf '@@@ /etc/karmada/config/karmada.config 0640\napiVersion: v1\nkind: Config\n'
    for u in $ALL; do printf '@@@ /etc/systemd/system/%s.service 0644\n[Service]\nExecStart=/usr/local/sbin/x\n' "$u"; done
  } > "$sb/stage/bundle.txt"
}

# 使い捨ての PKI(stage ごとに必要なものだけ)
mkpki() { # $1=apiserver|full
  local P="$sb/etc/pki" W="$sb/etc/webhook-cert"; mkdir -p "$P" "$W"
  for ca in ca front-proxy-ca etcd-ca; do
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$sb/ca/$ca.key" -out "$P/$ca.crt" -subj "/CN=$ca" -days 30 \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" >/dev/null 2>&1
  done
  leaf() { # $1=名前 $2=CA 名 $3=用途 $4=SAN(任意) $5=出力先ディレクトリ
    local d=${5:-$P}
    openssl req -new -newkey rsa:2048 -nodes -keyout "$d/$1.key" -out "$sb/ca/$1.csr" -subj "/CN=$1" >/dev/null 2>&1
    printf 'extendedKeyUsage=%s\n%s' "$3" "${4:+subjectAltName=$4}" > "$sb/ca/ext.cnf"
    openssl x509 -req -in "$sb/ca/$1.csr" -CA "$P/$2.crt" -CAkey "$sb/ca/$2.key" -CAcreateserial -days 30 -extfile "$sb/ca/ext.cnf" -out "$d/$1.crt" >/dev/null 2>&1
  }
  leaf apiserver ca serverAuth "IP:$ADV,IP:127.0.0.1,DNS:localhost"
  leaf front-proxy-client front-proxy-ca clientAuth
  leaf etcd-client etcd-ca clientAuth
  openssl genrsa -out "$P/karmada.key" 2048 >/dev/null 2>&1
  FPR=$(openssl pkey -in "$P/karmada.key" -pubout -outform der | sha256sum | cut -d' ' -f1)
  if [ "$1" = full ]; then
    leaf ionos-karmada-cp ca clientAuth
    leaf aggregated-apiserver ca serverAuth "DNS:karmada-aggregated-apiserver.karmada-system.svc"
    leaf metrics-adapter ca serverAuth "DNS:karmada-metrics-adapter.karmada-system.svc"
    openssl req -new -newkey rsa:2048 -nodes -keyout "$W/tls.key" -out "$sb/ca/w.csr" -subj "/CN=karmada-webhook" >/dev/null 2>&1
    printf 'extendedKeyUsage=serverAuth\nsubjectAltName=DNS:karmada-webhook.karmada-system.svc\n' > "$sb/ca/ext.cnf"
    openssl x509 -req -in "$sb/ca/w.csr" -CA "$P/ca.crt" -CAkey "$sb/ca/ca.key" -CAcreateserial -days 30 -extfile "$sb/ca/ext.cnf" -out "$W/tls.crt" >/dev/null 2>&1
  fi
}

# $1=stage、$2=START_UNITS
run() {
  local stage=$1 start=$2
  env PATH="$sb/bin:$PATH" ALLOW_NON_ROOT=1 STAGE="$stage" STAGE_DIR="$sb/stage" ALL_UNITS="$ALL" START_UNITS="$start" ADVERTISE="$ADV" \
    ETC_DIR="$sb/etc" SBIN_DIR="$sb/sbin" BIN_DIR="$sb/bindir" SYSTEMD_DIR="$sb/sysd" HOSTS_FILE="$sb/hosts" MEMINFO="$sb/meminfo" \
    SYSTEMCTL="$sb/bin/systemctl" CURL="$sb/bin/curl" JOURNALCTL="$sb/bin/journalctl" UFW="$sb/bin/ufw" \
    IPTABLES="$sb/bin/iptables" REDIRECT_TABLE="$sb/etc/redirect.table" \
    API_SOURCES="172.31.254.1,192.168.1.130" WG_IF=wg0 MIN_MEM_MB=700 MIN_AFTER_MB=250 WAIT_SECONDS=3 SETTLE_SECONDS=0 \
    KARMADA_KEY_FPR="${FPR:-}" \
    bash "$MEMBER" > "$sb/out" 2>&1
  rc=$?
}
called() { grep -q -- "$1" "$sb/calls"; }
active() { [ -f "$sb/sys/active-$1" ]; }

# ======================================================================================
# 1. prepare(新規): バイナリ・ユニット・hosts・REDIRECT・ufw を用意し、何も起動しない
mksb; run prepare ""
chk "prepare: 成功する" '[ $rc -eq 0 ]'
chk "prepare: 6 つのバイナリを配置し、実行権限がある" '[ "$(ls "$sb/sbin" | grep -c "^kube-apiserver$\|^karmada-")" -ge 6 ] && [ -x "$sb/sbin/kube-apiserver" ] && [ -x "$sb/sbin/karmada-webhook" ]'
chk "prepare: image 由来のバイナリは、crane で取り出す" 'called "crane export reg.test/karmada/karmada-webhook"'
chk "prepare: ユニット・slice・kubeconfig を配置した" '[ -f "$sb/sysd/karmada-cp.slice" ] && [ -f "$sb/sysd/karmada-apiserver.service" ] && [ -f "$sb/etc/config/karmada.config" ]'
chk "prepare: /etc/hosts に、管理するブロックが 1 つだけ入り、元の行も残る" '[ "$(grep -c "BEGIN karmada-cp" "$sb/hosts")" = 1 ] && grep -q "127.0.0.11  karmada-webhook.karmada-system.svc" "$sb/hosts" && grep -q "10.0.0.5 other-host" "$sb/hosts"'
chk "prepare: REDIRECT の 3 つのルールが入った(443 -> 実ポート)" '[ "$(wc -l < "$sb/ipt")" = 3 ] && grep -qx -- "-d 127.0.0.11 -p tcp --dport 443 -j REDIRECT --to-ports 8443" "$sb/ipt"'
chk "prepare: ufw は、wg0 の指定の送信元から、5443 だけを許可する" 'called "ufw allow in on wg0 from 172.31.254.1 to any port 5443 proto tcp" && called "ufw allow in on wg0 from 192.168.1.130 to any port 5443 proto tcp"'
chk "prepare: Karmada のサービスを、1 つも起動していない(REDIRECT のユニットは、inert なので、active でよい)" 'for u in $ALL; do active $u && exit 1; done; exit 0'
chk "prepare: systemctl が触れるのは、karmada-* のユニットと daemon-reload だけ(etcd・wg・frr・haproxy には、触れない)" '! grep "^systemctl" "$sb/calls" | grep -vE "daemon-reload|karmada-" | grep -q .'
chk "prepare: ufw は、5443 以外を触っていない" '! grep "^ufw" "$sb/calls" | grep -vq "port 5443 proto tcp"'

# 2. 冪等: 2 回目は、何も変えない(再ダウンロード・再配置・daemon-reload・hosts の重複なし)
: > "$sb/calls"; run prepare ""
chk "再実行: 成功する" '[ $rc -eq 0 ]'
chk "再実行: バイナリを再取得しない(curl の download も crane も呼ばない)" '! called "dl.test" && ! called "crane export"'
chk "再実行: daemon-reload しない(ユニットに変更なし)" '! called "daemon-reload"'
chk "再実行: hosts のブロックが重複しない" '[ "$(grep -c "BEGIN karmada-cp" "$sb/hosts")" = 1 ] && [ "$(grep -c "karmada-webhook.karmada-system.svc" "$sb/hosts")" = 1 ]'
chk "再実行: REDIRECT のルールが重複しない" '[ "$(wc -l < "$sb/ipt")" = 3 ]'

# 3. バイナリの SHA256 が違う: 配置しない
mksb
sed -i 's/^kube-apiserver|url|\(.*\)|\([0-9a-f]\{64\}\)$/kube-apiserver|url|\1|0000000000000000000000000000000000000000000000000000000000000000/' "$sb/stage/binaries.txt"
run prepare ""
chk "url のバイナリの SHA256 不一致: 中止し、配置しない" '[ $rc -ne 0 ] && [ ! -e "$sb/sbin/kube-apiserver" ] && grep -q "SHA256 が一致しません" "$sb/out"'
mksb
sed -i 's/^karmada-webhook|image|\(.*\)|\([0-9a-f]\{64\}\)$/karmada-webhook|image|\1|0000000000000000000000000000000000000000000000000000000000000000/' "$sb/stage/binaries.txt"
run prepare ""
chk "image のバイナリの SHA256 不一致: 中止し、配置しない" '[ $rc -ne 0 ] && [ ! -e "$sb/sbin/karmada-webhook" ] && grep -q "SHA256 が一致しません" "$sb/out"'
mksb; sed -i 's/^\(https:[^|]*\)|.*$/\1|0000000000000000000000000000000000000000000000000000000000000000/' "$sb/stage/crane.txt"
run prepare ""
chk "crane の tarball の SHA256 不一致: 中止する" '[ $rc -ne 0 ] && grep -q "crane の tarball" "$sb/out"'

# 4. bundle に、許可されていないパス: 中止する(想定外の場所に、書かない)
mksb; printf '@@@ /etc/passwd 0644\nevil\n' >> "$sb/stage/bundle.txt"
run prepare ""
chk "bundle に /etc/passwd: 中止する" '[ $rc -ne 0 ] && grep -q "許可されていないパス" "$sb/out"'
mksb; printf '@@@ /etc/systemd/system/../../passwd 0644\nevil\n' >> "$sb/stage/bundle.txt"
run prepare ""
chk "bundle にパス遡行(..): 中止する" '[ $rc -ne 0 ] && grep -q "許可されていないパス" "$sb/out"'

# 5. /etc/hosts: ブロックの更新(元の行は、そのまま)
mksb; run prepare ""
sed -i 's/127.0.0.13/127.0.0.99/' "$sb/stage/bundle.txt"
run prepare ""
chk "hosts: ブロックの内容が変わると更新され、重複せず、元の行は残る" '[ "$(grep -c "BEGIN karmada-cp" "$sb/hosts")" = 1 ] && grep -q "127.0.0.99" "$sb/hosts" && ! grep -q "127.0.0.13" "$sb/hosts" && grep -q "10.0.0.5 other-host" "$sb/hosts"'
chk "hosts: 初回の控え(.bak-karmada-cp)が、元の内容のまま残る" '[ -f "$sb/hosts.bak-karmada-cp" ] && ! grep -q karmada "$sb/hosts.bak-karmada-cp"'

# 6. stage=apiserver: 証明書・鍵が無い → 起動せずに中止
mksb; run apiserver "karmada-apiserver"
chk "apiserver: 証明書が無い: 起動せずに中止し、足りないファイルを表示する" '[ $rc -ne 0 ] && ! active karmada-apiserver && grep -q "足りないファイル" "$sb/out" && grep -q "apiserver.crt" "$sb/out"'

# 7. 鍵と証明書が対でない
mksb; mkpki apiserver; openssl genrsa -out "$sb/etc/pki/apiserver.key" 2048 >/dev/null 2>&1
run apiserver "karmada-apiserver"
chk "apiserver: 鍵と証明書が対でない: 起動せずに中止" '[ $rc -ne 0 ] && ! active karmada-apiserver && grep -q "対になっていません" "$sb/out"'

# 8. apiserver.crt の SAN に、待ち受けのアドレスが無い
mksb; mkpki apiserver
openssl req -new -newkey rsa:2048 -nodes -keyout "$sb/etc/pki/apiserver.key" -out "$sb/ca/a.csr" -subj "/CN=apiserver" >/dev/null 2>&1
printf 'extendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\n' > "$sb/ca/ext.cnf"
openssl x509 -req -in "$sb/ca/a.csr" -CA "$sb/etc/pki/ca.crt" -CAkey "$sb/ca/ca.key" -CAcreateserial -days 30 -extfile "$sb/ca/ext.cnf" -out "$sb/etc/pki/apiserver.crt" >/dev/null 2>&1
run apiserver "karmada-apiserver"
chk "apiserver: SAN に待ち受けのアドレスが無い: 中止" '[ $rc -ne 0 ] && grep -q "SAN に $ADV がありません" "$sb/out"'

# 9. 別の CA の証明書
mksb; mkpki apiserver
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$sb/ca/evil.key" -out "$sb/ca/evil.crt" -subj "/CN=evil" -days 30 >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -keyout "$sb/etc/pki/etcd-client.key" -out "$sb/ca/e.csr" -subj "/CN=etcd-client" >/dev/null 2>&1
printf 'extendedKeyUsage=clientAuth\n' > "$sb/ca/ext.cnf"
openssl x509 -req -in "$sb/ca/e.csr" -CA "$sb/ca/evil.crt" -CAkey "$sb/ca/evil.key" -CAcreateserial -days 30 -extfile "$sb/ca/ext.cnf" -out "$sb/etc/pki/etcd-client.crt" >/dev/null 2>&1
run apiserver "karmada-apiserver"
chk "apiserver: 想定外の CA が署名した証明書: 中止" '[ $rc -ne 0 ] && ! active karmada-apiserver && grep -q "CA で検証できません" "$sb/out"'

# 10. karmada.key の指紋の不一致
mksb; mkpki apiserver; FPR=0000000000000000000000000000000000000000000000000000000000000000
run apiserver "karmada-apiserver"
chk "apiserver: karmada.key の指紋が違う: 中止" '[ $rc -ne 0 ] && ! active karmada-apiserver && grep -q "指紋が、期待した値と違います" "$sb/out"'

# 11. メモリが足りない
mksb; mkpki apiserver; printf 'MemAvailable:    300000 kB\n' > "$sb/meminfo"
run apiserver "karmada-apiserver"
chk "apiserver: MemAvailable が足りない: 起動せずに中止" '[ $rc -ne 0 ] && ! active karmada-apiserver && grep -q "MemAvailable が足りません" "$sb/out"'

# 12. apiserver: 正常
mksb; mkpki apiserver; run apiserver "karmada-apiserver"
chk "apiserver: 正常に起動し、/readyz を確認する" '[ $rc -eq 0 ] && active karmada-apiserver && called "readyz"'
chk "apiserver: 他のコンポーネントは起動しない" '! active karmada-webhook && ! active karmada-scheduler'
chk "apiserver: 鍵は、サービスの実行ユーザーが読める権限(0640)になる" '[ "$(stat -c %a "$sb/etc/pki/karmada.key")" = 640 ] && [ "$(stat -c %a "$sb/etc/pki/apiserver.crt")" = 644 ]'
chk "apiserver: 証明書の内容(鍵)を、出力に出さない" '! grep -q "PRIVATE KEY" "$sb/out"'

# 13. /readyz が通らない: ロールバック
mksb; mkpki apiserver; touch "$sb/readyz_fail"; run apiserver "karmada-apiserver"
chk "apiserver: /readyz が通らない: apiserver を止めて、中止する(ロールバック)" '[ $rc -ne 0 ] && ! active karmada-apiserver && grep -q "readyz が通りませんでした" "$sb/out" && grep -q "journal:" "$sb/out"'

# 14. full: 正常
mksb; mkpki full; run full "$ALL"
chk "full: すべてのコンポーネントが起動する" '[ $rc -eq 0 ] && for u in $ALL; do active $u || exit 1; done'
chk "full: apiserver を、最初に起動し、/readyz を確認してから、他を起動する" 'a=$(grep -n "enable --now karmada-apiserver" "$sb/calls" | head -1 | cut -d: -f1); r=$(grep -n "readyz" "$sb/calls" | head -1 | cut -d: -f1); w=$(grep -n "enable --now karmada-webhook" "$sb/calls" | head -1 | cut -d: -f1); [ "$a" -lt "$r" ] && [ "$r" -lt "$w" ]'

# 15. full: 1 つが、起動できない → すべて止める
mksb; mkpki full; touch "$sb/failstart-karmada-scheduler"; run full "$ALL"
chk "full: 1 つ(scheduler)の起動が失敗: CP のサービスを、すべて止める" '[ $rc -ne 0 ] && for u in $ALL; do ! active $u || exit 1; done && grep -q "すべて止めます" "$sb/out"'

# 16. full: 起動して、しばらくあとに落ちる(再起動の繰り返し)
mksb; mkpki full; touch "$sb/crash-karmada-webhook"; run full "$ALL"
chk "full: 起動後に落ちるもの(webhook): CP のサービスを、すべて止める" '[ $rc -ne 0 ] && for u in $ALL; do ! active $u || exit 1; done && grep -q "再起動の繰り返し\|active でなくなりました" "$sb/out"'

# 17. full: 証明書が一部無い(ionos-karmada-cp)
mksb; mkpki full; rm -f "$sb/etc/pki/ionos-karmada-cp.crt"; run full "$ALL"
chk "full: ionos-karmada-cp.crt が無い: 起動せずに中止(apiserver も起動しない)" '[ $rc -ne 0 ] && ! active karmada-apiserver && grep -q "ionos-karmada-cp.crt" "$sb/out"'

# 18. stage を下げる: full -> prepare で、すべて止まり、無効になる(ロールバック)
mksb; mkpki full; run full "$ALL"; : > "$sb/calls"; run prepare ""
chk "full -> prepare: CP のサービスをすべて止め、無効にする(ロールバック)" '[ $rc -eq 0 ] && for u in $ALL; do ! active $u && [ ! -f "$sb/sys/enabled-$u" ] || exit 1; done'
chk "full -> prepare: REDIRECT のルールは残る(inert)" '[ "$(wc -l < "$sb/ipt")" = 3 ]'
chk "full -> prepare: etcd・wg・frr・haproxy には、触れない" '! grep "^systemctl" "$sb/calls" | grep -vE "daemon-reload|karmada-" | grep -q .'

# 19. stage を下げる: full -> apiserver で、apiserver 以外が止まる
mksb; mkpki full; run full "$ALL"; run apiserver "karmada-apiserver"
chk "full -> apiserver: apiserver だけが残る" '[ $rc -eq 0 ] && active karmada-apiserver && ! active karmada-webhook && ! active karmada-scheduler'

# 20. バイナリが変わったら、起動中のサービスを再起動する
mksb; mkpki apiserver; run apiserver "karmada-apiserver"
printf '#!/bin/sh\necho new\n' > "$sb/serve/kube-apiserver"
sed -i "s/^kube-apiserver|url|\(.*\)|[0-9a-f]\{64\}$/kube-apiserver|url|\1|$(sha256sum "$sb/serve/kube-apiserver" | cut -d' ' -f1)/" "$sb/stage/binaries.txt"
: > "$sb/calls"; run apiserver "karmada-apiserver"
chk "バイナリの更新: 起動中の apiserver を再起動する" '[ $rc -eq 0 ] && called "restart karmada-apiserver.service" && [ "$(sha256sum "$sb/sbin/kube-apiserver" | cut -d" " -f1)" = "$(sha256sum "$sb/serve/kube-apiserver" | cut -d" " -f1)" ]'

# ======================================================================================
# REDIRECT スクリプト単体
mksb
mkdir -p "$sb/r"; printf '127.0.0.11 8443\n127.0.0.12 7443\n' > "$sb/r/table"
rr() { env PATH="$sb/bin:$PATH" REDIRECT_TABLE="$sb/r/table" IPTABLES="$sb/bin/iptables" bash "$REDIR" "$1" > "$sb/out" 2>&1; rc=$?; }
rr start; rr start
chk "redirect: start は冪等(2 回で、ルールは 2 つ)" '[ "$(wc -l < "$sb/ipt")" = 2 ]'
rr status
chk "redirect: status が ok" '[ $rc -eq 0 ] && grep -q "ok      127.0.0.11:443 -> :8443" "$sb/out"'
rr stop; rr stop
chk "redirect: stop は冪等で、ルールが消える" '[ "$(wc -l < "$sb/ipt")" = 0 ] && [ $rc -eq 0 ]'
rr status
chk "redirect: ルールが無いと、status が失敗する" '[ $rc -ne 0 ] && grep -q "^missing" "$sb/out"'
printf '8.8.8.8 8443\n' > "$sb/r/table"; : > "$sb/ipt"; rr start
chk "redirect: ループバック以外のアドレスの表は、拒否する(ルールを足さない)" '[ $rc -ne 0 ] && [ ! -s "$sb/ipt" ] && grep -q "不正" "$sb/out"'
printf '127.0.0.11 8443; rm -rf /\n' > "$sb/r/table"; rr start
chk "redirect: 表に、余計な文字がある行は、拒否する" '[ $rc -ne 0 ] && [ ! -s "$sb/ipt" ]'
printf '127.0.0.11 abc\n' > "$sb/r/table"; rr start
chk "redirect: ポートが数字でない: 拒否する" '[ $rc -ne 0 ]'
: > "$sb/r/table"; rr start
chk "redirect: 表が空: 拒否する" '[ $rc -ne 0 ] && grep -q "表が空" "$sb/out"'

# ======================================================================================
# 入力の検証・hosts の保護・prepare の先行停止
mksb; run prepare ""
sed -i 's/^# BEGIN karmada-cp.*$/&/' "$sb/hosts"
printf '# BEGIN karmada-cp (managed by terraform: hardware/modules/karmada-cp-member)\n' >> "$sb/hosts"
cp "$sb/hosts" "$sb/hosts.before"
run prepare ""
chk "hosts: BEGIN だけで END が無い: 中止し、書き換えない" '[ $rc -ne 0 ] && grep -q "マーカーが壊れています" "$sb/out" && cmp -s "$sb/hosts" "$sb/hosts.before"'
mksb
sed -i 's|^\(kube-apiserver\)|\1|' "$sb/stage/binaries.txt"
printf 'evil;name|url|http://x|p|%s\n' "$(printf 'a%.0s' $(seq 64))" >> "$sb/stage/binaries.txt"
run prepare ""
chk "バイナリ名が不正: 中止する" '[ $rc -ne 0 ] && grep -q "バイナリ名が不正" "$sb/out"'
mksb
printf 'karmada-x|image|reg.test/x|../../etc/passwd|%s\n' "$(printf 'a%.0s' $(seq 64))" >> "$sb/stage/binaries.txt"
run prepare ""
chk "image 内の path に .. がある: 中止する" '[ $rc -ne 0 ] && grep -q "path が不正" "$sb/out"'
mksb
ADV_SAVE=$ADV; ADV='1.2.3.4;touch /tmp/pwned'
run prepare ""
ADV=$ADV_SAVE
chk "ADVERTISE が不正: 中止する(シェルに渡さない)" '[ $rc -ne 0 ] && grep -q "ADVERTISE が不正" "$sb/out" && [ ! -e /tmp/pwned ]'
mksb; mkpki apiserver; run apiserver "karmada-apiserver"
touch "$sb/stage/.x"
mksb; run prepare ""
chk "prepare: 失敗しうる作業の前に、サービスを止める(順序: 最初の systemctl が stop)" 'grep "^systemctl" "$sb/calls" | head -1 | grep -q "stop"'

echo "--- $pass passed, $fail failed"
exit $((fail > 0))
