# karmada-cp-member

Karmada の control plane(IONOS = CP #3)を IaC で構成する(kigawa-net/kigawa-net-k8s#268)。Inuyama の Karmada(Karmada Operator が Kubernetes 上に作る)と、**同じ etcd(3 メンバー)を共有する、別の control plane**。

**`stage = "prepare"`(既定)では、Karmada のサービスは、何も起動しない。**

## 構成
IONOS は、2 vCPU、メモリ 1.8GB(**swap なし**)で、**全拠点の WireGuard / BGP(FRR)/ HAProxy のハブ**。止めると、全拠点の経路に影響する。このため、**ゲートウェイと etcd を守る**設計にしている。

| コンポーネント | バイナリ | 待ち受け | 実測メモリ(Inuyama、1 Pod) |
|---|---|---|---|
| karmada-apiserver | `kube-apiserver` v1.36.2 | `172.31.254.2:5443`(WireGuard のアドレスだけ) | 240〜270MB |
| karmada-controller-manager | v1.19.0 | `127.0.0.1`(metrics `18081`、health `10357`) | 15〜37MB |
| karmada-scheduler | v1.19.0 | metrics `18082`、health `10351` | 約 12MB |
| karmada-webhook | v1.19.0 | `127.0.0.1:8443`(metrics `18083`、health `18003`) | 約 13MB |
| karmada-aggregated-apiserver | v1.19.0 | `127.0.0.1:7443` | 30〜73MB |
| karmada-metrics-adapter | v1.19.0 | `127.0.0.1:7444`(metrics `18084`) | 45〜49MB |

- **kube-controller-manager は、既定で動かさない**。Inuyama の kube-controller-manager は、CSR の署名(csrsigning)のために、apiserver の CA の**秘密鍵**(`ca.key`)を使っている。CA の秘密鍵を、公開 IP を持つ IONOS に置かない。また、leader election で動くため、鍵の無いインスタンスが leader になると、クラスター全体で CSR の署名が止まる。Inuyama の 2 レプリカで足りる。`enable_kube_controller_manager = true` にすると、`csrsigning` を外して動かせる(推奨しない)。
- **メモリの保護**: 6 つを、1 つの systemd slice(`karmada-cp.slice`、`MemoryHigh=650M`・`MemoryMax=800M`)にまとめ、各サービスに `OOMScoreAdjust=500`。OOM のとき、CP のサービスが先に落ちる(ゲートウェイは、巻き込まれない)。
- **起動の前の確認**: `MemAvailable` が `min_available_memory_mb`(既定 700MB)以上。起動後に 250MB を下回ったら、すべて止める。

## 名前解決(webhook と APIService)
Karmada の登録は、`*.karmada-system.svc` の名前で etcd に入っている(webhook 21 個は `url` 形式の `https://karmada-webhook.karmada-system.svc:443/<パス>`、APIService 4 つは `ExternalName` の Service を、ポート 443 で参照)。この host には Kubernetes の DNS が無いので、**ローカルに向ける**。

| 名前 | `/etc/hosts` | REDIRECT | 実際の待ち受け |
|---|---|---|---|
| `karmada-webhook.karmada-system.svc` | `127.0.0.11` | `127.0.0.11:443` → `:8443` | webhook |
| `karmada-aggregated-apiserver.karmada-system.svc` | `127.0.0.12` | `127.0.0.12:443` → `:7443` | aggregated-apiserver |
| `karmada-metrics-adapter.karmada-system.svc` | `127.0.0.13` | `127.0.0.13:443` → `:7444` | metrics-adapter |

- IONOS の HAProxy が `0.0.0.0:443` を占有しているため、ローカルでは 443 で待ち受けられない(`bind` が `EADDRINUSE`)。**`iptables` の REDIRECT なら、衝突しない**。コンテナ(iptables-nft、`0.0.0.0:443` を別のプロセスが占有)で検証済み(webhook の URL と同じ形が、TLS の名前の検証まで通る)。
- REDIRECT は `karmada-cp-redirect.service`(oneshot)で永続化する。**ufw の管理外**なので、`ufw reload` で消えない。スクリプトが、毎回、冪等な `start` を実行して、ルールを表に揃える(`iptables -C || -A`)。
- **表のポートを変えたときの、古いルールは、自動では消えない**(手動で `iptables -t nat -D OUTPUT …`)。
- `/etc/hosts` は、`# BEGIN karmada-cp` 〜 `# END karmada-cp` の**ブロックだけ**を置き換える(ブロックの外が変わらないことを確認してから書く。初回の控えは `/etc/hosts.bak-karmada-cp`)。

## 段階(`stage`)
| stage | 内容 |
|---|---|
| `prepare`(既定) | バイナリ・ユニット・slice・`/etc/hosts`・REDIRECT・ufw の許可(5443、wg 内の指定の送信元だけ)を用意する。**何も起動しない**。起動中の CP のサービスがあれば、止めて、無効にする(= **ロールバック**) |
| `apiserver` | 起動の前の確認のあと、kube-apiserver だけを起動し、`/readyz` が通ることを確認する |
| `full` | apiserver と、残りの 5 つを、1 つずつ起動する(起動直後と、数秒後の 2 回、active を確認し、再起動の繰り返しを検出する) |

**失敗したら、CP のサービスを、すべて止める**(`prepare` に戻す)。`etcd`・WireGuard・FRR・HAProxy には、触れない(systemctl の対象は、`karmada-*` のユニットだけ)。

## 証明書と鍵(この IaC の外で用意する)
秘密鍵を Terraform の state に入れないため、`/etc/karmada/pki/` に、**人の手で配置**する。署名は、CSR 方式(IONOS で鍵と CSR を作り、CA の鍵を持つ側で、検証して署名する)。

| ファイル | 内容 | 必要な stage |
|---|---|---|
| `ca.crt` | apiserver の CA の公開証明書(`karmada-apiserver-ca`) | apiserver |
| `front-proxy-ca.crt` | front-proxy の CA の公開証明書 | apiserver |
| `etcd-ca.crt` | etcd の CA の公開証明書 | apiserver |
| `apiserver.crt` / `.key` | apiserver のサービング。SAN に `172.31.254.2` を含む | apiserver |
| `front-proxy-client.crt` / `.key` | `CN=front-proxy-client`(`--requestheader-allowed-names` と一致) | apiserver |
| `etcd-client.crt` / `.key` | apiserver → etcd の client | apiserver |
| `karmada.key` | **ServiceAccount の署名鍵(管理者権限に相当する鍵)**。全 control plane で共有する。**人の手で配置する** | apiserver |
| `ionos-karmada-cp.crt` / `.key` | コンポーネントの client(`O=system:masters`、管理者権限) | full |
| `aggregated-apiserver.crt` / `.key` | SAN: `karmada-aggregated-apiserver.karmada-system.svc` | full |
| `metrics-adapter.crt` / `.key` | SAN: `karmada-metrics-adapter.karmada-system.svc` | full |
| `/etc/karmada/webhook-cert/tls.crt` / `tls.key` | SAN: `karmada-webhook.karmada-system.svc` | full |

起動の前に、スクリプトが次を確認し、1 つでも外れたら、**起動せずに中止**する。
- ファイルが揃っている(足りないものを、一覧で表示する)
- **鍵と証明書が対になっている**(公開鍵の照合)
- **想定の CA で検証できる**(`openssl verify -purpose`)。期限切れは中止、30 日以内は警告
- `apiserver.crt` の SAN に、待ち受けのアドレスがある
- **`karmada.key` の指紋**が、`karmada_key_fingerprint`(公開してよい情報)と一致する(転送の途中の破損・すり替えの検出)

鍵は、`root:karmada`、`0640` に直す(サービスの実行ユーザー `karmada` が読めるように)。

## バイナリ
- `kube-apiserver` / `kube-controller-manager`: `https://dl.k8s.io/release/v1.36.2/bin/linux/amd64/<名前>`。**公式の `.sha256` と一致**することを確認して、SHA256 をピン留め。
- Karmada のコンポーネント: **v1.19.0 のリリースには、バイナリが含まれない**(`karmadactl` だけ)ため、**image を digest で固定**し、`crane export` で取り出す。`crane`(単一の静的バイナリ、v0.22.1)は、公式の `checksums.txt` と一致した SHA256 でピン留め。IONOS に、コンテナのランタイムは入れない。
- すべて、配置の前に、**バイナリの SHA256 を照合**する(一致しなければ、配置しない)。置き換えは、原子的(`mv`)。起動中のサービスは、バイナリやユニットが変わったときだけ、再起動する。

## 参加の取り消し(ロールバック)
`stage = "prepare"` にして apply する(CP のサービスを、止めて、無効にする)。完全に外す場合は、さらに、手動で次を行う。
```bash
systemctl disable --now karmada-cp-redirect.service
iptables -t nat -S OUTPUT | grep 127.0.0.1[123]     # 残りがあれば、-D で削除
# /etc/hosts の BEGIN/END ブロックを削除(控え: /etc/hosts.bak-karmada-cp)
rm -f /etc/systemd/system/karmada-*.service /etc/systemd/system/karmada-cp.slice && systemctl daemon-reload
```

## 限界
- **メモリ**: swap が無く、余裕は約 400MB。slice の上限で、ゲートウェイは守るが、CP のサービスは、OOM で止まりうる。
- **IONOS 実機での REDIRECT の動作**: コンテナでは検証済み。IONOS の実機(カーネル 6.1)では、`prepare` のあとに、ダミーのリスナーで確認する(`nf_nat` などのモジュールが、初回に自動で読み込まれる)。
- **webhook(21 個)は、`failurePolicy: Fail`**: IONOS の webhook が応答しないと、IONOS の apiserver への書き込みが、失敗する。`full` に上げる前に、webhook への到達を確認する。
- **CA・鍵の総入れ替えの手順**は、まだ無い(IONOS の侵害は、`karmada.key` の漏えいを意味する)。

## テスト
```bash
bash hardware/modules/karmada-cp-member/test-karmada-cp-member.sh
```
偽の `systemctl` / `curl` / `crane` / `iptables` / `ufw`、使い捨ての CA を使い、実機にも、etcd にも、触れない。prepare・冪等・SHA256 不一致・bundle のパスの許可リスト・`/etc/hosts` のブロック・証明書の各種の不備(対、CA、SAN、指紋)・メモリ・起動の失敗とロールバック・stage の上げ下げ・REDIRECT のスクリプトを、確認する(51 件)。保護を 1 つずつ外す変異テストで、対応するテストが失敗することを確認した。
