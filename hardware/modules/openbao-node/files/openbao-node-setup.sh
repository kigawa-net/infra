#!/bin/bash
# OpenBao ノードの構築・更新(modules/openbao-node が remote-exec で、sudo 経由の bash で実行する)。
# 初期化(bao operator init)は、この script では行わない。鍵・root token は、どこにも保存しない。
#
# 必要な環境変数:
#   OPENBAO_VERSION       固定のバージョン(例: 2.7.2)。bao の版を確認する
#   DEB_URL               公式の .deb の URL
#   DEB_SHA256            .deb の SHA256(一致しなければ何もしない)
#   STAGE_DIR             Terraform が配置した一時ディレクトリ(設定・unit・証明書)。終了時に消す
#   WIPE_DATA_ON_FAILURE  1 のときだけ、失敗時に /var/lib/openbao を消す(既定 0)
# OPENBAO_ROOT は、テストで / の代わりに使う接頭辞(本番では空)。
set -eo pipefail
export PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

: "${OPENBAO_VERSION:?}" "${DEB_URL:?}" "${DEB_SHA256:?}" "${STAGE_DIR:?}" "${WIPE_DATA_ON_FAILURE:?}"
root="${OPENBAO_ROOT:-}"
bin="$root/usr/local/bin/bao"
etc="$root/etc/openbao"
data="$root/var/lib/openbao"
unit="$root/etc/systemd/system/openbao.service"

tmp=""
was_active=0
unit_existed=0
config_existed=0

die() { echo "openbao-node: $*" >&2; exit 1; }

# 失敗時は、このラン で足したものだけを戻す。/var/lib/openbao は、wipe_data_on_failure=1 のときだけ消す。
cleanup() {
  local rc=$?
  trap - EXIT
  # 秘密鍵・証明書を含むので、成否にかかわらず消す
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

# 3. 証明書(外部の CA で発行したもの)。秘密鍵を含め 0600、openbao 所有。内容が変わったら SIGHUP で再読込する
tls_changed=0
for f in tls.crt tls.key ca.crt; do
  if place "$STAGE_DIR/$f" "$etc/tls/$f" 0600 openbao:openbao; then tls_changed=1; fi
done

# 4. 設定と unit
config_changed=0
if place "$STAGE_DIR/openbao.hcl" "$etc/openbao.hcl" 0640 root:openbao; then config_changed=1; fi
if place "$STAGE_DIR/openbao.service" "$unit" 0644 root:root; then
  config_changed=1
  systemctl daemon-reload || die "daemon-reload に失敗しました"
fi

# 5. 起動・反映。初期化はしない(未初期化の sealed 状態で待機する)
systemctl enable openbao >/dev/null || die "enable に失敗しました"
if ! systemctl is-active --quiet openbao; then
  systemctl start openbao || die "起動に失敗しました(journalctl -u openbao を確認)"
elif [ "$config_changed" = 1 ]; then
  systemctl restart openbao || die "再起動に失敗しました"
elif [ "$tls_changed" = 1 ]; then
  systemctl reload openbao || die "証明書の再読込(SIGHUP)に失敗しました"
fi

echo "openbao-node: 完了($(systemctl is-active openbao))。未初期化のため、bao operator init は手動で行うこと"
