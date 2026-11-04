#!/usr/bin/env bash
# sudo パスワードの埋め込み(echo '…' | sudo -S …)の、引用符の安全性のテスト(kigawa-net/infra#441)。
# 実機にも Bitwarden にも触れない。terraform が無ければ、その部分は skip する。
#  1. 静的: *.tf に、エスケープしていない埋め込み、または echo での埋め込み(-n / -e を飲み込む)が残っていない
#  2. Terraform の式: replace(...) で作った文字列を bash に通すと、元のパスワードが、そのまま標準入力に届く(注入されない)
#  3. bash の式: data "external" の sudo_pass_q(sed)でも同じ
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   - $1"; }
ng()  { fail=$((fail+1)); echo "FAIL - $1"; }

# ---- 1. 静的
cnt=$(cd "$here" && git grep -nE 'echo .\$\{(var\.sudo_password|data\.external\.sudo_password\.result\.value|replace)|echo .\$sudo_pass|printf .%s.\\\\?n. .\$\{(var\.sudo_password|data\.external\.sudo_password\.result\.value)\}' -- '*.tf' 2>/dev/null | wc -l)
[ "$cnt" = 0 ] && ok "エスケープしていない埋め込みが、*.tf に無い" || ng "エスケープしていない埋め込みが $cnt 件ある"

# パスワードの候補(引用符・ドル・バッククォート・バックスラッシュ・空白・注入の試み)
PASSES=("plain123" "a'b" "'; echo PWNED >&2; #" 'a"b$c`d\e' "it's \$HOME" "  lead trail  " "-n" "''")

# ---- 2. Terraform の式
if command -v terraform >/dev/null 2>&1; then
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
  cat > "$t/main.tf" <<'TF'
variable "pw" {
  type      = string
  sensitive = true
}
locals {
  cmd = "printf '%s\\n' '${replace(var.pw, "'", "'\"'\"'")}' | cat"
}
output "cmd" {
  value     = local.cmd
  sensitive = true
}
TF
  terraform -chdir="$t" init -input=false -no-color >/dev/null 2>&1
  for p in "${PASSES[@]}"; do
    TF_VAR_pw="$p" terraform -chdir="$t" apply -auto-approve -input=false -no-color >/dev/null 2>&1
    cmd=$(terraform -chdir="$t" output -raw cmd 2>/dev/null)
    got=$(bash -c "$cmd" 2>/tmp/stderr.$$)
    if [ "$got" = "$p" ] && [ ! -s /tmp/stderr.$$ ]; then ok "Terraform の式: 元の値のまま届く"; else ng "Terraform の式: 値が変わった/注入された (入力=$p)"; fi
  done
  rm -f /tmp/stderr.$$
else
  echo "skip - terraform が無い(Terraform の式のテスト)"
fi

# ---- 3. bash の式(data "external" の sudo_pass_q)。ssh の代わりに bash -c で、同じ二重の解釈を再現
for p in "${PASSES[@]}"; do
  sudo_pass="$p"
  sudo_pass_q=$(printf '%s' "$sudo_pass" | sed "s/'/'\"'\"'/g")
  got=$(bash -c "printf '%s\\n' '$sudo_pass_q' | cat" 2>/tmp/stderr.$$)
  if [ "$got" = "$p" ] && [ ! -s /tmp/stderr.$$ ]; then ok "bash の式: 元の値のまま届く"; else ng "bash の式: 値が変わった/注入された (入力=$p)"; fi
done
rm -f /tmp/stderr.$$

echo "---"; echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
