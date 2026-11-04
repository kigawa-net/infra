#!/bin/bash
# 秘密(鍵・トークン・sudo パスワード)を、ホストの tmpfs(既定 /dev/shm/maas-wol-secrets)に一時的に置き、
# 使い終わったら必ず消すための、小さなヘルパー(kigawa-net/infra#416、PR #417 のレビュー対応)。
#
# 使い方(Terraform の remote-exec から、ファイルとして呼ぶ。秘密は、コマンド文字列(inline)に入れない):
#   bash secret-stage.sh prepare [名前...]   ディレクトリを作り直す(前回の残骸を消す)。名前のファイルを、0600 の空で作る
#   bash secret-stage.sh clean               ディレクトリと、古い置き場所(SECRET_STAGE_LEGACY)を消す
#   sudo -S ... secret-stage.sh run -- <cmd...>
#                                            <cmd> を実行し、終了コードを保ったまま、必ず clean する(trap EXIT)
#
# 環境変数: SECRET_STAGE_DIR(既定 /dev/shm/maas-wol-secrets)、SECRET_STAGE_LEGACY(空白区切りの、古い /tmp の置き場所。既定は、以前の設計の残骸)。
# tmpfs なので、再起動で消える。途中で接続が切れても、次の apply の prepare で必ず消す。
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
DIR=${SECRET_STAGE_DIR:-/dev/shm/maas-wol-secrets}
LEGACY=${SECRET_STAGE_LEGACY:-/tmp/maas-wol-shutdown.key /tmp/maas-wol-shutdown-targets.json /tmp/maas-wol-shutdown-known-hosts}

clean() {
  rm -rf -- "$DIR"
  # shellcheck disable=SC2086
  rm -f -- $LEGACY
}

prepare() {
  clean
  install -d -m 0700 "$DIR"
  local name
  for name in "$@"; do
    # 先に 0600 で作る(file provisioner は、既存のファイルの権限を保つ)
    install -m 0600 /dev/null "$DIR/$name"
  done
}

run() {
  [ "${1:-}" = "--" ] || { echo "usage: secret-stage.sh run -- <cmd...>" >&2; exit 2; }
  shift
  [ "$#" -gt 0 ] || { echo "usage: secret-stage.sh run -- <cmd...>" >&2; exit 2; }
  trap 'rc=$?; clean; exit $rc' EXIT
  # root として実行されたとき(sudo 経由)は、置いたファイルの所有者を root にする。
  # ディレクトリは、ssh ユーザーのまま(次の prepare が、ユーザーの権限で消せるように。ファイルは、ディレクトリの権限で消せる)。
  if [ "${SECRET_STAGE_UID:-$(id -u)}" = 0 ] && [ -d "$DIR" ]; then
    find "$DIR" -mindepth 1 -maxdepth 1 -type f -exec "${SECRET_STAGE_CHOWN:-chown}" root:root {} +
  fi
  "$@"
}

cmd=${1:-}
[ "$#" -gt 0 ] && shift
case "$cmd" in
  prepare) prepare "$@" ;;
  clean) clean ;;
  run) run "$@" ;;
  *) echo "usage: secret-stage.sh prepare [名前...] | clean | run -- <cmd...>" >&2; exit 2 ;;
esac
