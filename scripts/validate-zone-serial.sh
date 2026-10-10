#!/usr/bin/env bash
# hardware/zones/*.zone の変更で SOA の Serial が増えているかを検査する (issue #273)
#
# 背景:
#   infra#221 で knot の `zone-reload` を IaC に組み込んだが、reload が
#   反映するのは「Serial が増えたとき」だけである。zone ファイルにレコードを
#   足して Serial を据え置くと、reload は成功ログを出すのに DNS は古いままに
#   なり、apply が green でも結果が反映されない。
#
# 使い方:
#   scripts/validate-zone-serial.sh <base-ref>
#     base-ref 以降で変更された zone ファイルの Serial が、base-ref 時点で
#     の Serial より大きいかを検査する。
#     PR  : origin/<base_ref>
#     push: <before> HEAD
#   (base-ref を解決できない場合は、明示的に fetch してから実行すること)
#
# 終了コード:
#   0  Serial が増えている / 対象 zone が無い
#   1  Serial が増えていない / Serial が読めない / Serial が形式不正

set -uo pipefail

BASE_REF="${1:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "$BASE_REF" ]; then
  echo "ERROR: base ref を指定してください (例: scripts/validate-zone-serial.sh origin/main)" >&2
  exit 1
fi

# zone ファイルから SOA の Serial を 1 つ取り出す。
read_serial() {
  local file="$1"
  # SOA の Serial 行は、リポジトリ内の zone ファイルがすべて
  # 「<数値>   ; Serial」という形で書かれている(infra#273 で意図的に
  # この注釈を必須の目印にしている。Serial 行の書き方が崩れても
  # 検査が黙って通過しない)。
  #
  # 「括弧内の最初の数値」で取ると、Serial 行が削除・typo されたときに
  # refresh(10800)を掴んで「Serial の形式が不正」という、
  # 原因と関係ない理由を報告してしまう。注釈で明示的に判定する。
  awk '
    /SOA/ { in_soa = 1; next }
    in_soa && index($0, "; Serial") > 0 {
      line = $0
      sub(/;.*$/, "", line)
      if (match(line, /[0-9]+/)) {
        print substr(line, RSTART, RLENGTH)
        exit
      }
    }
  ' "$file"
}

# base ref は 1 つでも 2 つ(「<before> HEAD」形式)でも受け付ける。
# git diff は 2 つの commit の間 periphery を比較するため、2 つ渡された場合は
# そのまま diff の引数にする。1 つの場合は「その ref 以降」を比較する。
diff_args=()
read -r -a base_parts <<< "$BASE_REF"
for part in "${base_parts[@]}"; do
  if ! git -C "$REPO_ROOT" rev-parse --verify "$part" >/dev/null 2>&1; then
    echo "ERROR: base ref の '$part' を解決できません (fetch 不足?)" >&2
    exit 1
  fi
  diff_args+=("$part")
done

if [ "${#diff_args[@]}" -eq 1 ]; then
  diff_args+=("HEAD")
fi

# コミット済み差分に加え、作業ツリーの未コミット差分も対象にする。
# CI では commit 済みなので通常は差分ゼロだが、未コミットの zone を検査した
# のに「変更なし」と返ると黙って通ってしまうため、両方を見る。
changed_zones=$(
  {
    git -C "$REPO_ROOT" diff --name-only "${diff_args[@]}" -- 'hardware/zones/*.zone'
    git -C "$REPO_ROOT" diff --name-only HEAD -- 'hardware/zones/*.zone'
  } | sort -u
)

if [ -z "$changed_zones" ]; then
  echo "変更された zone ファイルはありません。スキップします。"
  exit 0
fi

status=0
echo "検査対象: $(echo "$changed_zones" | tr '\n' ' ')"
echo

for rel in $changed_zones; do
  file="$REPO_ROOT/$rel"

  new_serial="$(read_serial "$file")"
  if [ -z "$new_serial" ]; then
    echo "ERROR: $rel から SOA の Serial を読み取れませんでした" >&2
    status=1
    continue
  fi

  # Serial は YYYYMMDDnn の形式。形式が違えば比較そのものが
  # 意図しない結果になるため、比較の前に検査する。
  if ! printf '%s' "$new_serial" | grep -qE '^[0-9]{8}([0-9]{2})?$'; then
    echo "ERROR: $rel の Serial '$new_serial' の形式が不正です (YYYYMMDDnn 想定)" >&2
    status=1
    continue
  fi

  # 新規 zone(追加されたファイル)は比較対象が無いので成功扱い。
  if ! git -C "$REPO_ROOT" cat-file -e "${diff_args[0]}:$rel" 2>/dev/null; then
    echo "OK:   $rel は新規 zone (Serial=$new_serial、比較対象なし)"
    continue
  fi

  old_file="$(mktemp)"
  git -C "$REPO_ROOT" show "${diff_args[0]}:$rel" > "$old_file"
  old_serial="$(read_serial "$old_file")"
  rm -f "$old_file"

  if [ -z "$old_serial" ]; then
    echo "ERROR: ${diff_args[0]} の $rel から Serial を読み取れませんでした" >&2
    status=1
    continue
  fi

  if [ "$new_serial" -le "$old_serial" ]; then
    echo "ERROR: $rel の Serial が増えていません ($old_serial -> $new_serial)" >&2
    echo "       knot は Serial が増えたときだけ zone を反映するため、" >&2
    echo "       内容を変更したら Serial も増やさないと反映されません (#273)" >&2
    status=1
  else
    echo "OK:   $rel ($old_serial -> $new_serial)"
  fi
done

exit "$status"