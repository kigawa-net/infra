#!/bin/bash
# EasyTier のバイナリを、SHA-256 を照合してから入れ、systemd サービスとして起動する。
# 必須の環境変数: ET_VERSION(例: 2.7.0)、ET_ARCH(x86_64 / aarch64)、ET_SHA256(配布 zip の SHA-256)
# 設定ファイルは /tmp/easytier.toml(ET_CONFIG_SRC で変更可)から読む。
# ET_BIN_DIR / ET_CONF_DIR / ET_UNIT_DIR / ET_DOWNLOAD_BASE は、テスト(test-easytier-setup.sh)で差し替える。
set -eo pipefail
export PATH="${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive
umask 077

: "${ET_VERSION:?}" "${ET_ARCH:?}" "${ET_SHA256:?}"
bin_dir="${ET_BIN_DIR:-/usr/local/bin}"
conf_dir="${ET_CONF_DIR:-/etc/easytier}"
unit_dir="${ET_UNIT_DIR:-/etc/systemd/system}"
config_src="${ET_CONFIG_SRC:-/tmp/easytier.toml}"
base="${ET_DOWNLOAD_BASE:-https://github.com/EasyTier/EasyTier/releases/download}"
zip_name="easytier-linux-${ET_ARCH}-v${ET_VERSION}.zip"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 入っているバージョンが同じなら、ダウンロードを省く(設定だけ更新する)。
installed=""
if [ -x "$bin_dir/easytier-core" ]; then
  installed=$("$bin_dir/easytier-core" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
fi

if [ "$installed" != "$ET_VERSION" ]; then
  if ! command -v unzip >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y curl unzip
  fi
  curl -fsSL --retry 5 --retry-delay 3 -o "$work/$zip_name" "$base/v${ET_VERSION}/$zip_name"
  actual=$(sha256sum "$work/$zip_name" | cut -d' ' -f1)
  if [ "$actual" != "$ET_SHA256" ]; then
    echo "SHA-256 mismatch for $zip_name: expected=$ET_SHA256 actual=$actual" >&2
    exit 1
  fi
  unzip -q -o "$work/$zip_name" -d "$work/x"
  core=$(find "$work/x" -type f -name easytier-core | head -n1)
  cli=$(find "$work/x" -type f -name easytier-cli | head -n1)
  if [ -z "$core" ] || [ -z "$cli" ]; then
    echo "easytier-core / easytier-cli not found in $zip_name" >&2
    exit 1
  fi
  install -d -m 755 "$bin_dir"
  install -m 755 "$core" "$bin_dir/easytier-core"
  install -m 755 "$cli" "$bin_dir/easytier-cli"
fi

# Secret を含むので 0600。ディレクトリも root 専用。
install -d -m 700 "$conf_dir"
install -m 600 "$config_src" "$conf_dir/easytier.toml"

cat > "$unit_dir/easytier.service" <<UNIT
[Unit]
Description=EasyTier
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$bin_dir/easytier-core -c $conf_dir/easytier.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
chmod 644 "$unit_dir/easytier.service"

systemctl daemon-reload
systemctl enable easytier.service
systemctl restart easytier.service

echo "=== EasyTier ==="
"$bin_dir/easytier-core" --version || true
systemctl --no-pager --full status easytier.service || true
