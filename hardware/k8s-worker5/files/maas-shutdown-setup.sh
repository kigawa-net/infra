#!/bin/bash
# MAAS の /off(kigawa-net/infra#416)から、このノードを SSH で shutdown できるようにする受け口を作る(または消す)。
#
# - 専用ユーザー maas-shutdown。ログインは公開鍵だけ(パスワードはロック)。シェルは /bin/sh(forced command で使う)。
# - authorized_keys の 1 行で、from(Rack の IP)を制限し、forced command で「sudo -n shutdown -h now」だけを実行させる。
#   リモートコマンドは、クライアント(Rack の webhook)が指定できない。
# - sudoers は、maas-shutdown が /usr/sbin/shutdown -h now だけを、パスワード無しで実行できる 1 行。
#
# MAAS_SHUTDOWN_PUBLIC_KEY が空なら、受け口を消す(ユーザーと sudoers。無効化のため)。
# 環境変数: MAAS_SHUTDOWN_PUBLIC_KEY(ssh-ed25519 の 1 行)、MAAS_SHUTDOWN_ALLOWED_FROM(Rack の IPv4 をカンマ区切り。公開鍵があるとき必須)
#           ROOT(テスト用。既定は空=実機。home と sudoers.d を、ここの下に作る)、CHOWN(テスト用)、EXTRA_PATH(テストで偽のコマンドを差し込む)
# 冪等。sudoers は、一時ファイルに書いて visudo で検証してから置く(検証に失敗したら、既存の設定を壊さない)。
set -euo pipefail

export PATH="${EXTRA_PATH:+$EXTRA_PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

USER_NAME=maas-shutdown
ROOT=${ROOT:-}
KEY=${MAAS_SHUTDOWN_PUBLIC_KEY:-}
ALLOWED_FROM=${MAAS_SHUTDOWN_ALLOWED_FROM:-}
HOME_DIR="$ROOT/home/$USER_NAME"
SUDOERS_D="$ROOT/etc/sudoers.d"
SUDOERS="$SUDOERS_D/maas-shutdown"
CHOWN=${CHOWN:-chown}
tmp=""

die() { echo "ABORT: $*" >&2; exit 1; }

cleanup() {
  rc=$?
  [ -n "$tmp" ] && rm -f "$tmp"
  [ "$rc" = 0 ] || echo "[cleanup] 失敗(検証の後にだけ置くので、sudoers と authorized_keys は、途中で壊していない)" >&2
}
trap cleanup EXIT

remove_all() {
  rm -f "$SUDOERS"
  if id -u "$USER_NAME" >/dev/null 2>&1; then
    userdel -r "$USER_NAME"
  fi
  echo "maas-shutdown: 受け口を削除した(ユーザー・sudoers)"
}

install_all() {
  # 1. 入力の検証(ここまでは、何も変えない)
  # 改行や CR が入ると、authorized_keys に、別の行(オプションの注入)が作られるので、先に拒否する
  case "$KEY" in *$'\n'*|*$'\r'*) die "公開鍵は 1 行にする(改行は不可)" ;; esac
  local key_re='^ssh-ed25519 [A-Za-z0-9+/]+=*( [A-Za-z0-9@._+-]+)?$'
  [[ "$KEY" =~ $key_re ]] || die "公開鍵の形式が不正(ssh-ed25519 の 1 行のみ)"

  [ -n "$ALLOWED_FROM" ] || die "MAAS_SHUTDOWN_ALLOWED_FROM が空(from の無い鍵は作らない)"
  local ip_re='^[0-9]{1,3}(\.[0-9]{1,3}){3}$' ip o from_csv
  local -a froms=() octets=()
  IFS=',' read -r -a froms <<< "$ALLOWED_FROM"
  for ip in "${froms[@]}"; do
    [[ "$ip" =~ $ip_re ]] || die "from の IPv4 が不正($ip)"
    IFS='.' read -r -a octets <<< "$ip"
    for o in "${octets[@]}"; do
      [ "$((10#$o))" -le 255 ] || die "from の IPv4 が不正($ip)"
    done
  done
  local from_csv
  from_csv=$(IFS=,; echo "${froms[*]}")

  command -v visudo >/dev/null || die "visudo が無い(sudo を入れる)"

  # 2. sudoers を、一時ファイルに書いて検証する(ファイル名に . を含むので、sudo は読まない)
  mkdir -p "$SUDOERS_D"
  tmp=$(mktemp "$SUDOERS_D/.maas-shutdown.XXXXXX")
  printf '%s\n' "$USER_NAME ALL=(root) NOPASSWD: /usr/sbin/shutdown -h now" > "$tmp"
  chmod 0440 "$tmp"
  visudo -cf "$tmp" >/dev/null || die "sudoers の検証に失敗(既存の設定は変えていない)"
  # 検証に通ったら、先に置く。鍵の許可(手順 4)より前に置くのは、ここで失敗したときに、新しい鍵だけが有効になって
  # 「失敗と報告したのに、鍵は許可済み」にならないようにするため(sudoers だけが先にあっても、鍵が無ければ、誰もログインできない)。
  install -m 0440 "$tmp" "$SUDOERS"
  rm -f "$tmp"; tmp=""

  # 3. ユーザー(ログインできる最小限。パスワードはロック。冪等)
  if ! id -u "$USER_NAME" >/dev/null 2>&1; then
    useradd -m -s /bin/sh -c "MAAS の shutdown 用(kigawa-net/infra#416)" "$USER_NAME"
  fi
  usermod -s /bin/sh -L "$USER_NAME"

  # 4. authorized_keys: 一時ファイルに書いてから、置き換える(所有者は maas-shutdown、0600)
  mkdir -p "$HOME_DIR/.ssh"
  chmod 0700 "$HOME_DIR/.ssh"
  tmp=$(mktemp "$HOME_DIR/.ssh/.authorized_keys.XXXXXX")
  printf '%s\n' "restrict,from=\"$from_csv\",command=\"/usr/bin/sudo -n /usr/sbin/shutdown -h now\" $KEY" > "$tmp"
  chmod 0600 "$tmp"
  "$CHOWN" "$USER_NAME:$USER_NAME" "$HOME_DIR/.ssh" "$tmp"
  mv -f "$tmp" "$HOME_DIR/.ssh/authorized_keys"
  tmp=""

  echo "maas-shutdown: 受け口を設定した(from=$from_csv、forced command は sudo -n shutdown -h now のみ)"
}

if [ -n "$KEY" ]; then
  install_all
else
  remove_all
fi
