#!/usr/bin/env bash
# manifests-guard.sh のオフラインテスト。一時ディレクトリだけを使い、実機には触れない。
# 使い方: bash hardware/modules/manifests-guard/test-manifests-guard.sh
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/files/manifests-guard.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected=$2 actual=$3)"; fails=$((fails + 1)); fi; }

export MANIFESTS_DIR="$work/manifests" TEXTFILE_DIR="$work/textfile" LOGGER="$work/logger"
cat > "$work/logger" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/logger.log"
EOF
chmod +x "$work/logger"

pod() { # ファイル名 名前 [namespace]  -- kubeadm の static pod に近い最小の YAML
  local f="$MANIFESTS_DIR/$1"
  {
    echo "apiVersion: v1"; echo "kind: Pod"; echo "metadata:"
    echo "  creationTimestamp: null"
    [ -n "${2:-}" ] && echo "  name: $2"
    [ -n "${3:-}" ] && echo "  namespace: $3"
    echo "spec:"; echo "  containers:"; echo "  - name: $2"; echo "    image: example"
  } > "$f"
}
reset() { rm -rf "$MANIFESTS_DIR" "$TEXTFILE_DIR" "$work/logger.log"; mkdir -p "$MANIFESTS_DIR"; }
run() { bash "$script"; echo $?; }
metric() { grep -E "^$1 " "$TEXTFILE_DIR/k8s_manifests_guard.prom" 2>/dev/null | awk '{print $2}'; }
has() { grep -qF "$1" "$TEXTFILE_DIR/k8s_manifests_guard.prom" 2>/dev/null && echo yes || echo no; }

# 1. 健全: 通常の static pod(kubeadm のもの)+ 無視されるべき `.kubelet-keep`
reset
pod etcd.yaml etcd kube-system; pod kube-apiserver.yaml kube-apiserver kube-system; pod kube-vip.yaml kube-vip kube-system
touch "$MANIFESTS_DIR/.kubelet-keep"
check "healthy: exit 0" 0 "$(run)"
check "healthy: stray=0" 0 "$(metric k8s_manifests_stray_files)"
check "healthy: duplicate=0" 0 "$(metric k8s_manifests_duplicate_pods)"
check "healthy: last_run_success=1" 1 "$(metric k8s_manifests_guard_last_run_success)"
check "healthy: timestamp present" yes "$([ -n "$(metric k8s_manifests_guard_last_run_timestamp_seconds)" ] && echo yes || echo no)"
check "healthy: no logs" 0 "$([ -f "$work/logger.log" ] && wc -l < "$work/logger.log" | tr -d ' ' || echo 0)"

# 2. k8s1 の実例: etcd.yaml.bak(同じ pod 名は、.bak では「余分なファイル」として数える)
reset
pod etcd.yaml etcd kube-system; pod etcd.yaml.bak etcd kube-system
run >/dev/null
check "k8s1 case: stray=1" 1 "$(metric k8s_manifests_stray_files)"
check "k8s1 case: stray file is named in a label" yes "$(has 'k8s_manifests_stray_file{file="etcd.yaml.bak"} 1')"
check "k8s1 case: .bak is not parsed as a duplicate (it is stray, not yaml)" 0 "$(metric k8s_manifests_duplicate_pods)"
check "k8s1 case: logs the stray file" yes "$(grep -q 'etcd.yaml.bak' "$work/logger.log" && echo yes || echo no)"

# 3. k8s4 の実例: kube-apiserver.yaml.2025....bak が 4 つ
reset
pod kube-apiserver.yaml kube-apiserver kube-system
for t in 20250712174500 20250712174759 20250713110737 20250713111517; do pod "kube-apiserver.yaml.$t.bak" kube-apiserver kube-system; done
run >/dev/null
check "k8s4 case: stray=4" 4 "$(metric k8s_manifests_stray_files)"

# 4. `.yaml` どうしの重複(`.bak` ではなく、`foo.yaml` と `foo-old.yaml`)
reset
pod etcd.yaml etcd kube-system; pod etcd-old.yaml etcd kube-system; pod kube-vip.yaml kube-vip kube-system
run >/dev/null
check "duplicate yaml: duplicate=1" 1 "$(metric k8s_manifests_duplicate_pods)"
check "duplicate yaml: names both files" yes "$(has 'k8s_manifests_duplicate_pod{pod="kube-system/etcd",files="etcd-old.yaml, etcd.yaml"} 1')"
check "duplicate yaml: stray=0" 0 "$(metric k8s_manifests_stray_files)"

# 5. 同じ名前でも、namespace が違えば、重複ではない
reset
pod a.yaml web ns1; pod b.yaml web ns2
run >/dev/null
check "same name in different namespaces: not a duplicate" 0 "$(metric k8s_manifests_duplicate_pods)"

# 6. namespace が無いものは、default として扱う(同名なら重複)
reset
pod a.yaml web; pod b.yaml web
run >/dev/null
check "no namespace -> default: duplicate" 1 "$(metric k8s_manifests_duplicate_pods)"

# 7. `.yml` も、yaml として扱う。引用符・コメントつきの値も正しく読む
reset
{ echo "metadata:"; echo "  name: \"etcd\"   # コメント"; echo "  namespace: 'kube-system'"; } > "$MANIFESTS_DIR/a.yml"
pod b.yaml etcd kube-system
run >/dev/null
check ".yml with quotes and comment: parsed, duplicate=1" 1 "$(metric k8s_manifests_duplicate_pods)"
check ".yml is not stray" 0 "$(metric k8s_manifests_stray_files)"

# 8. `.` で始まるファイル(kubelet は無視する)は、余分なファイルに数えない
reset
pod etcd.yaml etcd kube-system; pod .etcd.yaml.bak etcd kube-system; touch "$MANIFESTS_DIR/.kubelet-keep"
run >/dev/null
check "dotfiles are ignored (kubelet ignores them)" 0 "$(metric k8s_manifests_stray_files)"

# 9. ファイル名に、引用符やバックスラッシュがあっても、メトリクスの形式を壊さない
reset
pod etcd.yaml etcd kube-system; : > "$MANIFESTS_DIR"'/my "odd" \name.bak'
run >/dev/null
check "odd file name is escaped in the label" yes "$(has 'k8s_manifests_stray_file{file="my \"odd\" \\name.bak"} 1')"
check "odd file name: the prom file still has 1 stray" 1 "$(metric k8s_manifests_stray_files)"

# 10. サブディレクトリは、数えない(kubelet は再帰しない)
reset
pod etcd.yaml etcd kube-system; mkdir -p "$MANIFESTS_DIR/old" && pod old/etcd.yaml etcd kube-system
run >/dev/null
check "subdirectories are ignored" 0 "$(( $(metric k8s_manifests_stray_files) + $(metric k8s_manifests_duplicate_pods) ))"

# 11. ファイルを変更・削除しない(読み取りだけ)
reset
pod etcd.yaml etcd kube-system; pod etcd.yaml.bak etcd kube-system
before=$(cd "$MANIFESTS_DIR" && sha256sum * | sha256sum)
run >/dev/null
after=$(cd "$MANIFESTS_DIR" && sha256sum * | sha256sum)
check "manifests are never modified" "$before" "$after"
check "the .bak is still there" yes "$([ -f "$MANIFESTS_DIR/etcd.yaml.bak" ] && echo yes || echo no)"

# 12. ディレクトリが無ければ、失敗として、メトリクスに書く(exit 1)
reset; rm -rf "$MANIFESTS_DIR"
check "missing dir: exit 1" 1 "$(run)"
check "missing dir: last_run_success=0" 0 "$(metric k8s_manifests_guard_last_run_success)"

# 13. 解消したら、メトリクスが 0 に戻る(同じファイルを上書き)
reset
pod etcd.yaml etcd kube-system; pod etcd.yaml.bak etcd kube-system
run >/dev/null
check "before cleanup: stray=1" 1 "$(metric k8s_manifests_stray_files)"
rm -f "$MANIFESTS_DIR/etcd.yaml.bak"
run >/dev/null
check "after cleanup: stray=0" 0 "$(metric k8s_manifests_stray_files)"
check "after cleanup: no leftover per-file label" no "$(has 'k8s_manifests_stray_file{')"

# 14. textfile の一時ファイルが残らない
check "no temp files left in textfile dir" 0 "$(find "$TEXTFILE_DIR" -name '.k8s_manifests_guard.prom.*' | wc -l | tr -d ' ')"

# --- 以下は、独立レビュー(Codex)で指摘された、見逃し・誤検知・失敗の隠れ方のケース ---

# 15. 字下げが 4 スペースの YAML でも、重複を見逃さない
reset
printf 'metadata:\n    name: etcd\n    namespace: kube-system\n' > "$MANIFESTS_DIR/a.yaml"
pod b.yaml etcd kube-system
run >/dev/null
check "4-space indentation: duplicate detected" 1 "$(metric k8s_manifests_duplicate_pods)"
check "4-space indentation: not unparsed" 0 "$(metric k8s_manifests_unparsed_files)"

# 16. CRLF(Windows の改行)でも、見逃さない
reset
printf 'metadata:\r\n  name: etcd\r\n  namespace: kube-system\r\n' > "$MANIFESTS_DIR/a.yaml"
pod b.yaml etcd kube-system
run >/dev/null
check "CRLF: duplicate detected" 1 "$(metric k8s_manifests_duplicate_pods)"

# 17. labels の中の name: は、pod 名ではない(metadata の直下の name: だけを見る)
reset
printf 'metadata:\n  labels:\n    name: other\n    namespace: nope\n  name: etcd\n  namespace: kube-system\n' > "$MANIFESTS_DIR/a.yaml"
pod b.yaml etcd kube-system
run >/dev/null
check "nested labels.name is ignored: duplicate on the real name" 1 "$(metric k8s_manifests_duplicate_pods)"
check "nested labels.name is ignored: pod is kube-system/etcd" yes "$(has 'k8s_manifests_duplicate_pod{pod="kube-system/etcd"')"

# 18. 複数ドキュメントは、最初のドキュメントだけを見る(kubelet と同じ)
reset
printf -- '---\nmetadata:\n  name: etcd\n  namespace: kube-system\n---\nmetadata:\n  name: other\n  namespace: kube-system\n' > "$MANIFESTS_DIR/a.yaml"
pod b.yaml etcd kube-system
run >/dev/null
check "multi-document: uses the first document (duplicate on etcd)" 1 "$(metric k8s_manifests_duplicate_pods)"
check "multi-document: the second document's name is not used" no "$(has 'kube-system/other')"

# 19. フロー形式の metadata
reset
printf 'metadata: {name: etcd, namespace: kube-system}\n' > "$MANIFESTS_DIR/a.yaml"
pod b.yaml etcd kube-system
run >/dev/null
check "flow-style metadata: duplicate detected" 1 "$(metric k8s_manifests_duplicate_pods)"

# 20. .yaml の中身が JSON(kubelet は受け付ける)
reset
printf '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"etcd","namespace":"kube-system"}}\n' > "$MANIFESTS_DIR/a.yaml"
pod b.yaml etcd kube-system
run >/dev/null
check "JSON content in .yaml: duplicate detected" 1 "$(metric k8s_manifests_duplicate_pods)"

# 21. 解析できなかったファイルは、見逃しではなく、unparsed として見える
reset
printf 'not: a pod\n' > "$MANIFESTS_DIR/weird.yaml"
pod etcd.yaml etcd kube-system
run >/dev/null
check "unparsed file is counted" 1 "$(metric k8s_manifests_unparsed_files)"
check "unparsed file is named" yes "$(has 'k8s_manifests_unparsed_file{file="weird.yaml"} 1')"
check "unparsed file is not a duplicate" 0 "$(metric k8s_manifests_duplicate_pods)"

# 22. ファイル名にカンマがあっても、1 つのファイルは重複ではない
reset
pod 'etcd,old.yaml' etcd kube-system
run >/dev/null
check "comma in a single file name is not a duplicate" 0 "$(metric k8s_manifests_duplicate_pods)"
reset
pod 'a,b.yaml' etcd kube-system; pod c.yaml etcd kube-system
run >/dev/null
check "comma in a file name: real duplicate is still 1" 1 "$(metric k8s_manifests_duplicate_pods)"

# 23. 読めないファイル・ディレクトリは、成功にしない(root では権限を無視できるので、スキップ)
if [ "$(id -u)" != "0" ]; then
  reset
  pod a.yaml etcd kube-system; pod b.yaml etcd kube-system; chmod 000 "$MANIFESTS_DIR/b.yaml"
  check "unreadable yaml: exit 1" 1 "$(run)"
  check "unreadable yaml: last_run_success=0" 0 "$(metric k8s_manifests_guard_last_run_success)"
  chmod 644 "$MANIFESTS_DIR/b.yaml"
  reset
  pod a.yaml etcd kube-system; chmod 000 "$MANIFESTS_DIR"
  check "unreadable directory: exit 1" 1 "$(run)"
  check "unreadable directory: last_run_success=0" 0 "$(metric k8s_manifests_guard_last_run_success)"
  chmod 755 "$MANIFESTS_DIR"
fi

# 24. メトリクスを書けないときは、exit 1(systemd が失敗を見つけられる)
if [ "$(id -u)" != "0" ]; then
  reset
  pod etcd.yaml etcd kube-system
  mkdir -p "$TEXTFILE_DIR" && chmod 555 "$TEXTFILE_DIR"
  check "unwritable textfile dir: exit 1" 1 "$(run)"
  chmod 755 "$TEXTFILE_DIR"
fi

if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
