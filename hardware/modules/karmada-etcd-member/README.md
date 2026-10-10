# karmada-etcd-member

Karmada の外部 etcd のメンバー(IONOS = etcd #3)を IaC で構成し、必要なら **learner** として参加させる(kigawa-net/kigawa-net-k8s#272、親 #268)。

## 何をするか
`files/karmada-etcd-member.sh` が、ホスト上で冪等に次を行う。

1. etcd / etcdctl を、指定バージョンで入れる(tarball の SHA256 をピン留め。すでに同じバージョンなら何もしない)
2. `etcd` ユーザーとデータディレクトリを用意する(`/etc/etcd` と `pki` は、`root:etcd` の 0750)
3. 証明書が置かれ、**etcd ユーザーで読める**ことを確認する(`/etc/etcd/pki/{ca.crt,tls.crt,tls.key}`、SAN に自分のアドレスを含む)
4. systemd ユニットと環境ファイル(`/etc/etcd/etcd.env`)を、Terraform の内容に揃える
5. **`join = true` のときだけ**、既存のメンバーに `member add --learner` して、起動する

`join = false`(既定)の間は、1〜4 だけで、**参加も起動もしない**。参加済みなら、何もしない(設定が変わったときだけ、再起動する)。

## 参加の前提(`join = true` にする前に)
1. **learner の数の上限**: etcd 3.6 の `--max-learners` の既定は **1**。すでに別の learner(Soichiro)がいるなら、IONOS の `member add --learner` は、`too many learner members` で失敗する(登録はされず、何も変わらない)。次のどちらかが要る。
   - 既存のメンバー(Inuyama の etcd、kigawa-net-k8s `karmada-etcd/statefulset.yaml`)に `--max-learners=2` を足す。**唯一の voter の再起動を伴い、その間は Karmada の API が止まる**。
   - 先に Soichiro を promote して、learner を 0 にする。**2 つ目の voter で quorum が 2 になり、どちらかが止まるだけで書き込みが止まる**時間が生じる(IONOS が追いつくまで)。
2. 証明書の用意(kigawa-net-k8s#268 の手順)。
3. promote の順序(下記)を決めておく。

## 失敗したときの動き
- 登録の後で失敗したら、**登録を取り消してから**、ローカルのデータを消す(learner なので、安全)。取り消しを確認できないときは、**データを残し**、手動の手順を表示する(登録が残ったまま、データだけ消えると、再実行で回復できなくなるため)。
- 前回の、登録だけで起動しなかった learner(自分の失敗の残り)は、次の実行で外して、やり直す。
- `member add` の応答だけが失われ、登録が済んでいる場合も、取り消す。
- 「準備できた」の判定は、一覧に `started` で載ることに加えて、このホストの etcd が実際に応答すること(`endpoint status`)。

## やらないこと(意図的)
- **learner の promote**。ほかの learner も追いついてから、続けて promote する(手動、別の判断)。
- **証明書と秘密鍵の管理**。秘密鍵を Terraform の state に入れないため、この IaC の外で用意する。
- 既存のメンバーの設定変更(Inuyama の etcd は、kigawa-net-k8s 側)。

## promote の手順(手動)
すべての learner が追いついた(`endpoint status --cluster` の raft index がそろう)後で、続けて実行する。

```bash
etcdctl member promote <Soichiro の ID>
etcdctl member promote <IONOS の ID>
```

## 参加の取り消し
**順序が重要**: 先に登録を外し、成功を確認してから、データを消す(登録が残ったまま、データだけ消えると、回復できなくなる)。

```bash
# 1. IONOS で、停止する(停止を確認する)
systemctl disable --now karmada-etcd && systemctl is-active karmada-etcd   # inactive になること
# 2. 既存のメンバーで、登録を外す(learner は、いつでも外せる。成功を確認する)
etcdctl member remove <IONOS の ID>
etcdctl member list -w table                                                # IONOS が無いこと
# 3. IONOS で、データを消す
rm -rf /var/lib/karmada-etcd/member
```

## 再 apply の動き
- `join = false`: ユニット・環境ファイルを、内容が変わったときだけ更新する。etcd の start / stop / restart は、しない。
- `join = true` で参加済み: ユニット・環境ファイルの内容が変わったとき(コメントだけの変更を含む)に、**このメンバーを再起動する**。メンバーが 3 つの voter になった後は、1 台の再起動なら quorum は保たれるが、同時に複数のメンバーが変更されないよう、1 台ずつ apply すること。

## 暫定の設定
`peer_skip_client_san_verification = true` は、kigawa-net-k8s#272 の案 A(peer の client 証明書の SAN と、接続元 IP の照合を外す)。送信元アドレスが SNAT で変わり、SAN と合わないため。CA の署名の検証は残る。根本案 B(送信元を固定する)に移ったら、`false` にする。

## テスト
```bash
bash hardware/modules/karmada-etcd-member/test-karmada-etcd-member.sh
```
偽の `etcdctl` / `systemctl` で、新規参加、`join = false`、参加済み、登録済み、残骸、voter 無し、起動失敗、空白付き ID、取り消し失敗、準備できない、learner 上限、応答喪失、証明書(無し・etcd が読めない)、接続不可を確認する。実機にも etcd にも触れない。
