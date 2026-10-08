#!/usr/bin/env bash
# /etc/kubernetes/manifests/ の余分なファイルと、pod 名の重複を検知して、node_exporter の textfile に書く(kigawa-net/infra#263)。
#
# kubelet は、このディレクトリの「`.` で始まらない」全てのファイルを static pod の定義として読む。
# 手作業で置かれた `etcd.yaml.bak` などが残ると、同じ pod 名を複数のファイルが定義し、どれが採用されるかが不定になる。
# 実際に、k8s1 の etcd と k8s4 の kube-apiserver が、古い `.bak` の内容で動いていた。
#
# このスクリプトは、検知するだけで、ファイルを一切変更・削除しない。
#   - 余分なファイル: `.yaml` / `.yml` 以外の、`.` で始まらないファイル(kubelet が読んでしまうもの)
#   - 重複した pod: 同じ namespace/name を定義する `.yaml` / `.yml` が 2 つ以上あるもの
#   - 解析できなかったファイル: `.yaml` / `.yml` だが、namespace/name を取り出せなかったもの(重複を見逃しうる)
# スキャンを完了できなかったとき(ディレクトリ・ファイルが読めない、メトリクスを書けない)は、成功にしない(exit 1)。
set -u

MANIFESTS_DIR="${MANIFESTS_DIR:-/etc/kubernetes/manifests}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
LOGGER="${LOGGER:-logger}"
DATE="${DATE:-date}"
PYTHON="${PYTHON:-python3}"

log() { "$LOGGER" -t manifests-guard -- "$*" 2>/dev/null || echo "manifests-guard: $*" >&2; }

# ラベルの値のエスケープ(\ " と改行)
esc() { printf '%s' "$1" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# 1 ファイルから namespace/name を取り出す。kubelet と同じく、最初のドキュメントだけを見る。
#   - ブロック形式の YAML(字下げは何スペースでもよい)、フロー形式(metadata: {name: x, namespace: y})
#   - JSON(.yaml の中身が JSON のもの。kubelet は受け付ける。python3 の標準ライブラリで読む)
# 取り出せなければ、何も出力しない。
pod_key() {
  local f="$1" first
  first=$(tr -d '\r' < "$f" | grep -m1 -v -E '^[[:space:]]*(#|$|---)' | sed 's/^[[:space:]]*//' | cut -c1)
  if [ "$first" = "{" ]; then
    "$PYTHON" - "$f" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    m = d.get("metadata", {})
    if m.get("name"):
        print((m.get("namespace") or "default") + "/" + m["name"])
except Exception:
    pass
PY
    return 0
  fi
  tr -d '\r' < "$f" | awk '
    function clean(v) { sub(/[ \t]*#.*$/, "", v); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); gsub(/["\047]/, "", v); return v }
    # 最初のドキュメントだけ(内容が出たあとの `---` で終わる)
    /^---/ { if (seen) exit; next }
    /^[ \t]*(#|$)/ { next }
    { seen = 1 }
    # フロー形式: metadata: {name: etcd, namespace: kube-system}
    /^metadata:[ \t]*\{/ {
      line = $0
      if (match(line, /name:[ \t]*[^,}]+/)) { v = substr(line, RSTART, RLENGTH); sub(/^name:[ \t]*/, "", v); name = clean(v) }
      if (match(line, /namespace:[ \t]*[^,}]+/)) { v = substr(line, RSTART, RLENGTH); sub(/^namespace:[ \t]*/, "", v); ns = clean(v) }
      next
    }
    /^metadata:/ { inmeta = 1; indent = -1; next }
    inmeta {
      match($0, /^[ \t]*/); cur = RLENGTH
      if (cur == 0) { inmeta = 0 }                 # 字下げのない行 = metadata の終わり
      else {
        if (indent < 0) indent = cur                # metadata の直下の字下げ(最初の子の字下げ)
        if (cur == indent) {
          if ($0 ~ /^[ \t]*name:/)      { v = $0; sub(/^[ \t]*name:/, "", v);      name = clean(v) }
          if ($0 ~ /^[ \t]*namespace:/) { v = $0; sub(/^[ \t]*namespace:/, "", v); ns = clean(v) }
        }
      }
    }
    END { if (name != "") print (ns == "" ? "default" : ns) "/" name }
  ' 2>/dev/null
}

out="$TEXTFILE_DIR/k8s_manifests_guard.prom"
# メトリクスを書く。成功なら 0。失敗(ディレクトリを作れない、書けない、置き換えられない)は 1
write_out() {
  mkdir -p "$TEXTFILE_DIR" 2>/dev/null || return 1
  local tmp="$TEXTFILE_DIR/.k8s_manifests_guard.prom.$$"
  if ! printf '%s\n' "$1" > "$tmp" 2>/dev/null; then rm -f "$tmp" 2>/dev/null; return 1; fi
  mv "$tmp" "$out" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

header() { # 引数: 成功か(1/0)
  cat <<EOF
# HELP k8s_manifests_guard_last_run_success スキャンを完了できたか (1/0)
# TYPE k8s_manifests_guard_last_run_success gauge
k8s_manifests_guard_last_run_success $1
# HELP k8s_manifests_guard_last_run_timestamp_seconds 直近の実行の時刻
# TYPE k8s_manifests_guard_last_run_timestamp_seconds gauge
k8s_manifests_guard_last_run_timestamp_seconds $("$DATE" +%s)
EOF
}

fail() { # 引数: 理由
  log "scan incomplete: $1"
  write_out "$(header 0)" || log "cannot write metrics to $TEXTFILE_DIR"
  exit 1
}

[ -d "$MANIFESTS_DIR" ] && [ -r "$MANIFESTS_DIR" ] && [ -x "$MANIFESTS_DIR" ] || fail "cannot read $MANIFESTS_DIR"

stray_lines=""; stray_count=0
unparsed_lines=""; unparsed_count=0
declare -A pod_files=()
declare -A pod_count=()
incomplete=""

# glob は、`.` で始まるファイルに一致しない(kubelet が無視するものと同じ)
for f in "$MANIFESTS_DIR"/*; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  [ -f "$f" ] || continue            # サブディレクトリは、kubelet が再帰しないので、対象外
  base=$(basename "$f")
  case "$base" in
    *.yaml|*.yml)
      # 読めること(権限)と、実際に最後まで読めること(消えた・I/O エラー)を確かめる。
      # pod_key は、読み取りの失敗を握りつぶして「取り出せなかった」にするので、ここで成功扱いにしない。
      if [ ! -r "$f" ] || ! tr -d '\r' < "$f" > /dev/null 2>&1; then incomplete="cannot read $base"; continue; fi
      key=$(pod_key "$f")
      if [ -n "$key" ]; then
        pod_files["$key"]="${pod_files["$key"]:+${pod_files["$key"]}, }$base"
        pod_count["$key"]=$(( ${pod_count["$key"]:-0} + 1 ))
      else
        unparsed_count=$((unparsed_count + 1))
        unparsed_lines="${unparsed_lines}k8s_manifests_unparsed_file{file=\"$(esc "$base")\"} 1"$'\n'
        log "cannot extract namespace/name from $base (a duplicate may be missed)"
      fi
      ;;
    *)
      stray_count=$((stray_count + 1))
      stray_lines="${stray_lines}k8s_manifests_stray_file{file=\"$(esc "$base")\"} 1"$'\n'
      log "stray file in $MANIFESTS_DIR (kubelet reads it as a static pod): $base"
      ;;
  esac
done
[ -z "$incomplete" ] || fail "$incomplete"

dup_lines=""; dup_count=0
for key in "${!pod_count[@]}"; do
  if [ "${pod_count[$key]}" -ge 2 ]; then
    dup_count=$((dup_count + 1))
    dup_lines="${dup_lines}k8s_manifests_duplicate_pod{pod=\"$(esc "$key")\",files=\"$(esc "${pod_files[$key]}")\"} 1"$'\n'
    log "duplicate static pod $key defined by: ${pod_files[$key]}"
  fi
done

body="$(header 1)
# HELP k8s_manifests_stray_files .yaml/.yml 以外で、kubelet が static pod として読んでしまうファイルの数
# TYPE k8s_manifests_stray_files gauge
k8s_manifests_stray_files $stray_count
# HELP k8s_manifests_duplicate_pods 同じ namespace/name を複数のファイルが定義している static pod の数
# TYPE k8s_manifests_duplicate_pods gauge
k8s_manifests_duplicate_pods $dup_count
# HELP k8s_manifests_unparsed_files .yaml/.yml だが namespace/name を取り出せなかったファイルの数(重複を見逃しうる)
# TYPE k8s_manifests_unparsed_files gauge
k8s_manifests_unparsed_files $unparsed_count
${stray_lines}${dup_lines}${unparsed_lines}"
write_out "${body%$'\n'}" || { log "cannot write metrics to $TEXTFILE_DIR"; exit 1; }
exit 0
