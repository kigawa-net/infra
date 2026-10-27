#!/usr/bin/env bash
# easytier-setup.sh のオフラインテスト。偽の curl / systemctl と、ローカルで作った zip を使うので、実機にも GitHub にも触れない。
# 使い方: bash hardware/modules/easytier/test-easytier-setup.sh
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/files/easytier-setup.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
check() { # 名前 期待 実際
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected=$2 actual=$3)"; fails=$((fails + 1)); fi
}

version=9.9.9
zip_name="easytier-linux-x86_64-v${version}.zip"
mkdir -p "$work/dl/v${version}" "$work/fakebin" "$work/pkg"
printf '#!/bin/sh\necho "easytier-core %s"\n' "$version" > "$work/pkg/easytier-core"
printf '#!/bin/sh\necho cli\n' > "$work/pkg/easytier-cli"
chmod +x "$work/pkg/"*
(cd "$work/pkg" && zip -q "$work/dl/v${version}/$zip_name" easytier-core easytier-cli)
sha=$(sha256sum "$work/dl/v${version}/$zip_name" | cut -d' ' -f1)

# 偽 curl: -o の出力先へ、ローカルの zip をコピーする(URL の末尾が dl 配下のパスに対応する)。
cat > "$work/fakebin/curl" <<'EOS'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;;
  esac
done
cp "$FAKE_DL/${url#file://}" "$out" 2>/dev/null || cp "${url#file://}" "$out"
EOS
printf '#!/bin/sh\necho "systemctl $*" >> "$FAKE_LOG"\n' > "$work/fakebin/systemctl"
chmod +x "$work/fakebin/"*

printf 'instance_name = "t"\n[network_identity]\nnetwork_secret = "s3cret"\n' > "$work/easytier.toml"

run() { # sha
  rm -rf "$work/root"; mkdir -p "$work/root/unit"; : > "$work/log"
  PATH="$work/fakebin:$PATH" FAKE_LOG="$work/log" FAKE_DL="$work/dl" \
    ET_VERSION="$version" ET_ARCH=x86_64 ET_SHA256="$1" \
    ET_BIN_DIR="$work/root/bin" ET_CONF_DIR="$work/root/etc" ET_UNIT_DIR="$work/root/unit" \
    ET_CONFIG_SRC="$work/easytier.toml" ET_DOWNLOAD_BASE="file://$work/dl" \
    bash "$script" > "$work/out" 2>&1
}

# 1. SHA-256 が違うと、何も入れずに失敗する
run "$(printf '0%.0s' $(seq 1 64))"; rc=$?
check "SHA 不一致は失敗する" 1 "$rc"
check "SHA 不一致ではバイナリを入れない" "no" "$([ -e "$work/root/bin/easytier-core" ] && echo yes || echo no)"
check "SHA 不一致では設定を書かない" "no" "$([ -e "$work/root/etc/easytier.toml" ] && echo yes || echo no)"

# 2. SHA-256 が合えば、バイナリ・設定・unit を入れてサービスを起動する
run "$sha"; rc=$?
check "SHA 一致は成功する" 0 "$rc"
check "easytier-core を入れる" "yes" "$([ -x "$work/root/bin/easytier-core" ] && echo yes || echo no)"
check "設定ファイルは 0600" "600" "$(stat -c %a "$work/root/etc/easytier.toml")"
check "設定ディレクトリは 0700" "700" "$(stat -c %a "$work/root/etc")"
check "Secret は unit に出さない" "0" "$(grep -c s3cret "$work/root/unit/easytier.service")"
check "unit は設定ファイルを指す" "1" "$(grep -c -- "-c $work/root/etc/easytier.toml" "$work/root/unit/easytier.service")"
check "サービスを restart する" "1" "$(grep -c 'systemctl restart easytier.service' "$work/log")"

# 3. 同じバージョンが入っていれば、ダウンロードしない(zip を消しても成功し、設定は更新される)
mv "$work/dl/v${version}/$zip_name" "$work/dl/v${version}/moved.zip"
printf 'instance_name = "t2"\n' > "$work/easytier.toml"
PATH="$work/fakebin:$PATH" FAKE_LOG="$work/log" FAKE_DL="$work/dl" \
  ET_VERSION="$version" ET_ARCH=x86_64 ET_SHA256="$sha" \
  ET_BIN_DIR="$work/root/bin" ET_CONF_DIR="$work/root/etc" ET_UNIT_DIR="$work/root/unit" \
  ET_CONFIG_SRC="$work/easytier.toml" ET_DOWNLOAD_BASE="file://$work/dl" \
  bash "$script" > "$work/out" 2>&1; rc=$?
check "同じバージョンなら再ダウンロードしない" 0 "$rc"
check "設定は更新される" "1" "$(grep -c t2 "$work/root/etc/easytier.toml")"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
