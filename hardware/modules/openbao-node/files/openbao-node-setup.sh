#!/bin/bash
# OpenBao ノードの構築・更新(modules/openbao-node が remote-exec で、sudo 経由の bash で実行する)。
# 初期化(bao operator init)は、この script では行わない。鍵・root token は、どこにも保存しない。
# TLS の証明書は、ノード自身が certbot(Let's Encrypt、DNS-01 / Cloudflare)で発行・更新する。秘密鍵は Terraform を通らない。
#
# 必要な環境変数:
#   OPENBAO_VERSION       固定のバージョン(例: 2.7.2)。bao の版を確認する
#   DEB_URL               公式の .deb の URL
#   DEB_SHA256            .deb の SHA256(一致しなければ何もしない)
#   STAGE_DIR             Terraform が配置した一時ディレクトリ(設定・unit・Cloudflare の資格情報・hosts の内容)。終了時に消す
#   WIPE_DATA_ON_FAILURE  1 のときだけ、失敗時に /var/lib/openbao を消す(既定 0)
#   FQDN                  このノードの証明書の名前(例: bao-02.kigawa.net)
#   ACME_EMAIL            Let's Encrypt の連絡先。空なら --register-unsafely-without-email で登録する
#   ACME_STAGING          1 なら Let's Encrypt の staging を使う(試験用。信頼されない証明書)
# OPENBAO_ROOT は、テストで / の代わりに使う接頭辞(本番では空)。
set -eo pipefail
export PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

: "${OPENBAO_VERSION:?}" "${DEB_URL:?}" "${DEB_SHA256:?}" "${STAGE_DIR:?}" "${WIPE_DATA_ON_FAILURE:?}"
: "${FQDN:?}" "${ACME_STAGING:?}"
root="${OPENBAO_ROOT:-}"
bin="$root/usr/local/bin/bao"
etc="$root/etc/openbao"
data="$root/var/lib/openbao"
unit="$root/etc/systemd/system/openbao.service"
le="$root/etc/letsencrypt"
live="$le/live/$FQDN"
hook_name="openbao-tls.sh"
hook_dst="$le/renewal-hooks/deploy/$hook_name"
hosts="$root/etc/hosts"
HOSTS_BEGIN="# BEGIN openbao-node (managed by terraform)"
HOSTS_END="# END openbao-node"

tmp=""
was_active=0
unit_existed=0
config_existed=0

die() { echo "openbao-node: $*" >&2; exit 1; }

# 失敗時は、このラン で足したものだけを戻す。/var/lib/openbao は、wipe_data_on_failure=1 のときだけ消す。
# 発行済みの証明書と cloudflare.ini は、戻さない(再発行はレート制限に当たるため)。
cleanup() {
  local rc=$?
  trap - EXIT
  # Cloudflare の token を含むので、成否にかかわらず消す
  rm -rf "$STAGE_DIR"
  if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
  if [ "$rc" -ne 0 ]; then
    echo "openbao-node: 失敗したので、このラン で足したものを戻します" >&2
    if [ "$was_active" = 0 ]; then
      systemctl stop openbao >/dev/null 2>&1 || true
    fi
    if [ "$unit_existed" = 0 ] && [ -e "$unit" ]; then
      rm -f "$unit"
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if [ "$config_existed" = 0 ]; then
      rm -f "$etc/openbao.hcl"
    fi
    if [ "$WIPE_DATA_ON_FAILURE" = 1 ]; then
      rm -rf "$data"
      echo "openbao-node: WARNING: wipe_data_on_failure=1 のため $data を削除しました" >&2
    elif [ -e "$data" ]; then
      echo "openbao-node: $data は残しました(削除は wipe_data_on_failure=1 のときだけ)。初期化済みのデータは、消さない" >&2
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT

# 内容(または mode)が変わって置き換えたときは 0 を返す。同じなら 1 を返す。
# install の失敗は die で止める(if の条件内では set -e が効かないため)。
place() {
  local src="$1" dst="$2" mode="$3" owner="$4"
  local replaced=1
  if [ ! -f "$dst" ] || ! cmp -s "$src" "$dst" || [ "$(stat -c '%a' "$dst")" != "${mode#0}" ]; then
    install -m "$mode" "$src" "$dst" || die "$dst を配置できません"
    replaced=0
  fi
  if [ "$(id -u)" -eq 0 ]; then
    chown "$owner" "$dst" || die "$dst の所有者を設定できません"
  fi
  return "$replaced"
}

# /etc/hosts の管理ブロックを、STAGE_DIR/hosts.entries の内容に合わせる(他の行は触らない。内容が同じなら書き換えない)
update_hosts() {
  local new="$STAGE_DIR/hosts.new"
  mkdir -p "$(dirname "$hosts")" || die "$(dirname "$hosts") を作れません"
  [ -f "$hosts" ] || : > "$hosts"
  {
    awk -v b="$HOSTS_BEGIN" -v e="$HOSTS_END" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$hosts"
    echo "$HOSTS_BEGIN"
    cat "$STAGE_DIR/hosts.entries"
    echo "$HOSTS_END"
  } > "$new" || die "hosts の内容を作れません"
  if ! cmp -s "$new" "$hosts"; then
    cat "$new" > "$hosts" || die "$hosts を書けません"
  fi
}

[ -e "$unit" ] && unit_existed=1
[ -e "$etc/openbao.hcl" ] && config_existed=1
if systemctl is-active --quiet openbao 2>/dev/null; then was_active=1; fi

# 1. バイナリ: 固定バージョンの .deb を SHA256 で検証してから取り出す(apt 追従にしない)
tmp=$(mktemp -d)
curl -fsSL -o "$tmp/bao.deb" "$DEB_URL" || die "ダウンロードに失敗しました"
echo "$DEB_SHA256  $tmp/bao.deb" | sha256sum -c - >/dev/null 2>&1 || die ".deb の SHA256 が一致しません"
dpkg-deb -x "$tmp/bao.deb" "$tmp/pkg" || die ".deb を展開できません"
install -D -m 0755 "$tmp/pkg/usr/bin/bao" "$bin" || die "bao を配置できません"
version_out=$("$bin" version) || die "bao version に失敗しました"
echo "$version_out" | grep -q "$OPENBAO_VERSION" || die "bao のバージョンが $OPENBAO_VERSION ではありません"

# 2. 専用ユーザーと、ディレクトリ
id openbao >/dev/null 2>&1 || useradd --system --home-dir /var/lib/openbao --no-create-home --shell /usr/sbin/nologin openbao
install -d -m 0750 "$etc" "$etc/tls" || die "$etc を作れません"
install -d -m 0755 "$(dirname "$unit")" || die "unit の置き場を作れません"
install -d -m 0700 "$data" || die "$data を作れません"
if [ "$(id -u)" -eq 0 ]; then
  chown root:openbao "$etc" "$etc/tls"
  chown openbao:openbao "$data"
fi

# 3. certbot と Cloudflare プラグイン(apt。既に入っていれば何もしない)
if ! dpkg -s certbot python3-certbot-dns-cloudflare >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq || die "apt-get update に失敗しました"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot python3-certbot-dns-cloudflare || die "certbot の導入に失敗しました"
fi
install -d -m 0755 "$le" "$le/renewal-hooks/deploy" || die "$le を作れません"

# 4. Cloudflare の資格情報(Terraform が STAGE_DIR に置いた ini。0600 root)。内容は表示しない
place "$STAGE_DIR/cloudflare.ini" "$le/cloudflare.ini" 0600 root:root || true

# 5. /etc/hosts: 自分と他ノードの fqdn を、WireGuard の IP に向ける(公開 DNS には A レコードを置かない)
update_hosts

# 6. TLS 証明書: ノード自身が Let's Encrypt から発行する(DNS-01 / Cloudflare)。
# 既にあれば発行しない。ただし staging と本番を切り替えたときは、発行し直す。
if [ -f "$live/fullchain.pem" ]; then
  have_staging=0
  if [ -f "$le/renewal/$FQDN.conf" ] && grep -q 'acme-staging' "$le/renewal/$FQDN.conf"; then have_staging=1; fi
  if [ "$have_staging" != "$ACME_STAGING" ]; then
    echo "openbao-node: acme_staging が変わったので、既存の証明書を消して発行し直します" >&2
    certbot delete --cert-name "$FQDN" --non-interactive >/dev/null || die "既存の証明書を消せません"
  fi
fi
if [ ! -f "$live/fullchain.pem" ]; then
  email_args=(--register-unsafely-without-email)
  if [ -n "${ACME_EMAIL:-}" ]; then email_args=(--email "$ACME_EMAIL"); fi
  staging_args=()
  if [ "$ACME_STAGING" = 1 ]; then staging_args=(--staging); fi
  certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$le/cloudflare.ini" \
    -d "$FQDN" --non-interactive --agree-tos "${email_args[@]}" "${staging_args[@]}" \
    || die "証明書の発行に失敗しました(Cloudflare のトークンと権限、DNS-01 を確認)"
fi

# deploy hook: certbot が発行・更新に成功したときに、証明書を OpenBao の配置先へ写し、起動中なら SIGHUP で再読込する。
# 秘密鍵の内容は、このファイルに入れない(パスを渡すだけ)。
cat > "$STAGE_DIR/$hook_name" <<HOOK
#!/bin/bash
# certbot の deploy hook(modules/openbao-node が配置する。手で編集しない)。
# certbot が発行・更新に成功したときに、RENEWED_LINEAGE を設定して呼ぶ。
set -eo pipefail
# この node の証明書(${FQDN})の更新だけを扱う
[ "\$(basename "\${RENEWED_LINEAGE:-}")" = "${FQDN}" ] || exit 0
dst="\${OPENBAO_TLS_DIR:-/etc/openbao/tls}"
install -m 0600 "\$RENEWED_LINEAGE/fullchain.pem" "\$dst/tls.crt.new"
install -m 0600 "\$RENEWED_LINEAGE/privkey.pem" "\$dst/tls.key.new"
if [ "\$(id -u)" -eq 0 ]; then
  chown openbao:openbao "\$dst/tls.crt.new" "\$dst/tls.key.new"
fi
mv -f "\$dst/tls.crt.new" "\$dst/tls.crt"
mv -f "\$dst/tls.key.new" "\$dst/tls.key"
if systemctl is-active --quiet openbao; then
  systemctl reload openbao
fi
HOOK
place "$STAGE_DIR/$hook_name" "$hook_dst" 0755 root:root || true

# 証明書があり、OpenBao 側の tls.crt / tls.key と違う(または無い)ときは、hook と同じ処理で配る。
# 初回の発行直後と、配置先が消えたときに通る。
if [ -f "$live/fullchain.pem" ] && { [ ! -f "$etc/tls/tls.crt" ] || [ ! -f "$etc/tls/tls.key" ] \
   || ! cmp -s "$live/fullchain.pem" "$etc/tls/tls.crt" || ! cmp -s "$live/privkey.pem" "$etc/tls/tls.key"; }; then
  RENEWED_LINEAGE="$live" OPENBAO_TLS_DIR="$etc/tls" "$hook_dst" || die "証明書を OpenBao の配置先へ配れません"
fi
[ -s "$etc/tls/tls.crt" ] && [ -s "$etc/tls/tls.key" ] || die "TLS の証明書が無いため、OpenBao を起動できません"

# 更新は certbot.timer が行う(Debian の certbot パッケージの timer。有効化だけ確認する)
systemctl enable --now certbot.timer >/dev/null || die "certbot.timer を有効にできません"

# 7. 設定と unit
config_changed=0
if place "$STAGE_DIR/openbao.hcl" "$etc/openbao.hcl" 0640 root:openbao; then config_changed=1; fi
if place "$STAGE_DIR/openbao.service" "$unit" 0644 root:root; then
  config_changed=1
  systemctl daemon-reload || die "daemon-reload に失敗しました"
fi

# 監査ログのローテーション(logrotate の設定)。ログの置き場所は、unit の LogsDirectory=openbao(/var/log/openbao)
install -d -m 0755 "$root/etc/logrotate.d" || die "logrotate.d を作れません"
place "$STAGE_DIR/openbao.logrotate" "$root/etc/logrotate.d/openbao" 0644 root:root || true

# 8. 起動・反映。初期化はしない(未初期化の sealed 状態で待機する)。証明書の更新は deploy hook が reload する
systemctl enable openbao >/dev/null || die "enable に失敗しました"
if ! systemctl is-active --quiet openbao; then
  systemctl start openbao || die "起動に失敗しました(journalctl -u openbao を確認)"
elif [ "$config_changed" = 1 ]; then
  systemctl restart openbao || die "再起動に失敗しました"
fi
# Type=simple の unit は、`systemctl start` が成功しても、直後に設定エラーで落ちることがある(2.7.2 の disable_mlock など)。
# 少し待って、動き続けていることを確認する(失敗したら、直近のログを出して止める)
sleep "${OPENBAO_START_WAIT:-5}"
if ! systemctl is-active --quiet openbao; then
  journalctl -u openbao --no-pager -n 10 >&2 2>/dev/null || true
  die "起動後に OpenBao が止まりました(上のログを確認)"
fi

echo "openbao-node: 完了($(systemctl is-active openbao))。未初期化のため、bao operator init は手動で行うこと"
