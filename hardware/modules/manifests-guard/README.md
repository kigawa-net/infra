# manifests-guard

`/etc/kubernetes/manifests/` の余分なファイルと、pod 名の重複を検知して、メトリクスに書く(issue #263)。**検知するだけで、ファイルは変更・削除しない。**

## なぜ必要か
kubelet は、このディレクトリの「`.` で始まらない」**全てのファイル**を static pod の定義として読む。手作業で置かれた `etcd.yaml.bak` などが残ると、同じ pod 名を複数のファイルが定義し、**どれが採用されるかが不定**になる。2026-10-08 に、次の 2 件が見つかった。

- k8s1: `etcd.yaml.bak` が採用され、etcd のメトリクスが `127.0.0.1:2381` のままだった(Prometheus に取れていなかった)。
- k8s4: `kube-apiserver.yaml.2025071*.bak`(OIDC つき)が採用され、k8s1 / k8s2 と構成が食い違っていた。

## 仕組み
systemd timer(`manifests-guard.timer`、5 分おき)が `manifests-guard.sh` を動かし、`/var/lib/node_exporter/textfile/k8s_manifests_guard.prom` を書く(node_exporter の textfile collector が読む)。

| メトリクス | 意味 |
|---|---|
| `k8s_manifests_stray_files` | `.yaml` / `.yml` 以外で、`.` で始まらないファイルの数(kubelet が読んでしまうもの) |
| `k8s_manifests_stray_file{file="…"}` | その各ファイル名 |
| `k8s_manifests_duplicate_pods` | 同じ `namespace/name` を、複数の `.yaml` / `.yml` が定義している pod の数 |
| `k8s_manifests_duplicate_pod{pod="…",files="a,b"}` | その各 pod と、定義しているファイル |
| `k8s_manifests_guard_last_run_success` / `…_timestamp_seconds` | 直近の実行の成否と時刻 |

アラート(`kigawa01/k8s-system` の `prometheus/manifests-guard-rules.yml`): `K8sManifestsStrayFiles`(warning)、`K8sManifestsDuplicatePods`(critical)、`K8sManifestsGuardStale`(検知が止まった)。

## 限界(正直に)
- **「余分なファイル」の検知は、YAML の解析に依存しない**。`.bak` など(今回の 2 件)は、これで確実に拾える。
- 「重複した pod」の検知は、awk による簡易な解析(ブロック形式・字下げの違い・CRLF・フロー形式・JSON・最初のドキュメントだけ)。次の特殊な書き方は、**見逃しうる**: エスケープされた名前(`"\x65tcd"`)、折りたたみスカラー(`name: >-`)、入れ子のフロー形式(`metadata: {labels: {name: x}, name: y}`)、`metadata` の重複、空の最初のドキュメント。kubeadm が作るマニフェストと、そのコピー(`.bak`)は、すべて通常のブロック形式なので、実害は想定していない。
- 解析できなかった `.yaml` は、`k8s_manifests_unparsed_files` に数える(見逃しの可能性が見える)。
- スキャンを完了できなかったとき(読めない、メトリクスを書けない)は、成功にしない(`exit 1`、`last_run_success=0`)。

## 検知されたら
```bash
ls -la /etc/kubernetes/manifests/
journalctl -t manifests-guard --since "-1h"
```
余分なファイルは、`/etc/kubernetes/manifests/` の**外**(例: `/root/`)へ退避する。**退避すると、kubelet が static pod を、残ったファイルの内容で再起動する**。再起動の前に、次を確認すること。
- 残るファイルの内容が、現在動いているものと同じか(実行中のコンテナの引数と比べる: `crictl inspect <id>`)。**違う場合は、退避で、動作が変わる**(2026-10-08 の k8s4 の例では、OIDC が外れた)。
- control-plane は、1 台ずつ(quorum と VIP のため)。

## テスト
`bash hardware/modules/manifests-guard/test-manifests-guard.sh`(一時ディレクトリだけを使うオフラインテスト)。
