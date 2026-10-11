#!/usr/bin/env bash
# bws CLI を固定バージョンで導入する (issue #190)
#
# 背景:
#   以前は GitHub の releases API から「最新の bws-v*」を動的に解決していた。
#   供給元が差し替えられた場合に検出できないため、supply-chain の
#   trust boundary を明確にする (#190)。
#
# 対策:
#   - version を明示する(BWS_VERSION)
#   - release に同梱された checksum ファイル(bws-sha256-checksums-<ver>.txt)と
#     照合してから install する
#
# version の更新はこのファイルの BWS_VERSION を書き換えるだけで済む。
set -euo pipefail

# bws のバージョン。bitwarden/sdk-sm の release タグに対応する。
BWS_VERSION="${BWS_VERSION:-bws-v2.1.0}"
BWS_TAG="${BWS_VERSION#bws-v}"

ZIP="bws-x86_64-unknown-linux-gnu-${BWS_TAG}.zip"
SUMS="bws-sha256-checksums-${BWS_TAG}.txt"
BASE="https://github.com/bitwarden/sdk-sm/releases/download/${BWS_VERSION}"

# release に同梱された checksum リストを使って、${ZIP} の期待値を取る。
# (checksum ファイル自体も同じ release のアセットなので、同じ release から取得する)
curl -L --retry 5 --retry-delay 3 --retry-all-errors -o "SHA256SUMS" "${BASE}/${SUMS}"
expected=$(grep -E "[[:space:]]${ZIP}\$" SHA256SUMS | awk '{print $1}')
if [ -z "$expected" ]; then
  echo "ERROR: ${SUMS} に ${ZIP} の checksum がありません" >&2
  exit 1
fi

curl -L --retry 5 --retry-delay 3 --retry-all-errors -o "${ZIP}" "${BASE}/${ZIP}"
echo "${expected}  ${ZIP}" | sha256sum -c - || {
  echo "ERROR: ${ZIP} の checksum が一致しません" >&2
  exit 1
}

unzip -o "${ZIP}" bws >/dev/null
rm -f "${ZIP}" SHA256SUMS
chmod 0755 bws
sudo mv bws /usr/local/bin/
bws --version