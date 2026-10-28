# OpenBao の復旧手順と、復元試験の記録

設計は `docs/openbao-implementation-design.md` §7、バックアップの仕組みは `hardware/modules/openbao-backup/README.md`。
**バックアップは、復元できて初めて意味がある。** このファイルは、復元の手順と、試験の記録を持つ。

## 前提

- バックアップは、ionos-01 の `openbao-backup.timer`(6 時間おき)が、Raft のスナップショットを age(公開鍵)で暗号化して、B2 のバケット `kigawa-net-bao`(Object Lock)に置く。世代は `6h/`、`daily/`、`weekly/`、`monthly/`、`adhoc/`。各ファイルに、側ファイル `<key>.sha256` がある。
- **復号の秘密鍵は、オフラインと Bitwarden にだけある**(ホストにも、この repo にも、会話にも置かない)。
- 復元に必要なもの: ① 暗号化スナップショット(B2)、② age の秘密鍵、③ **スナップショットの時点の Unseal 鍵(5 つのうち 3 つ)**。③ が無いと、復元しても Unseal できない。

## 復元の手順(隔離した環境で。通常の復旧も、同じ手順)

1. 対象の世代を選び、B2 から、暗号化スナップショットと、側ファイル `.sha256` を取得する(読み取り権限のキー)。`sha256sum` が側ファイルと一致しなければ、使わない。
2. **秘密鍵を持つ人間が**、復号する: `age -d -i <秘密鍵> -o raft.snap <取得したファイル>`。
3. 復元先の OpenBao ノードを起動し、**初期化して Unseal する**(復元先の鍵は、使い捨て)。
4. `bao operator raft snapshot restore -force raft.snap`(別の初期化をしたノードへの復元には `-force` が要る。**本番の復旧で、既存の Raft の構成と合うノードに戻すときは、`-force` を付けない**)。
5. **スナップショットの時点の鍵で、Unseal する**(復元後は、barrier の鍵が、スナップショットの元の鍵に戻る)。token も、スナップショットの時点のものに戻る。**復元先で作った試験用の token は、無効になる。**
6. 確認: `bao auth list`、`bao policy read <名前>`、`bao read auth/approle/role/<名前>`、KV の canary の読み取り。
7. 後片付け: `shred -u raft.snap`、データのディレクトリを消し、`unset BAO_TOKEN`。

### 注意(試験で分かったこと)

- **403 `permission denied` は、無効な token でも、権限がない場合でも出る。** 復元の直後は、試験用の token が無効になっているので、403 になる。`BAO_TOKEN` の環境変数は、`bao login` で保存した token より優先される。`unset BAO_TOKEN` してから `bao login` で、スナップショットの時点の root token を入れ直す。
- 本番のクラスタに復元するときは、リーダーのノードに復元する(他のノードは、リーダーから複製される)。復元の前に、**必ず、直前のスナップショットを追加で取る**(`openbao-backup.sh --reason pre-restore`)。

## 復元試験の記録

### 2026-10-28(1 回目)

| 項目 | 内容 |
|---|---|
| 目的 | バックアップから、本番の構成(認証方式・Policy・AppRole)が復元できるか |
| スナップショット | `6h/20261028T121843Z.raft.snap.age`(22,241 バイト、暗号化後) |
| 復元先 | 手元の PC の、使い捨ての 1 ノード(OpenBao 2.7.2、`127.0.0.1` だけ、Raft ストレージ) |
| 結果 | **合格** |
| 確認できたこと | 復号に成功(age の公開鍵と秘密鍵が一致)/ 側ファイルの sha256 が一致 / Raft の構成が本番のもの(5 分割・しきい値 3、`cluster_name` も本番)に戻った / 本番の鍵 3 つで Unseal できた / `approle/`、Policy `openbao-backup`、AppRole の role(`token_ttl 10m`、`token_num_uses 10`、CIDR 制限 `10.250.0.2/32` など)がすべて戻った |
| 確認できていないこと | KV の Secret の復元(この時点では、Secret が 1 つも入っていない)。復元にかかる時間(RTO)の実測。bao-02 / bao-03 の 2 ノードの本番への復元 |
| 所要時間(おおよそ) | 取得・復号・起動・初期化・復元・Unseal・確認で、30 分程度(手作業、待ちを含む) |
| 次回の予定 | Secret が入ったあと、月次で再実施する。KV の canary の読み取りを含める |

## 未実装

- 月次の自動復元テスト(使い捨ての環境で、復号の秘密鍵を使わずに、どこまで検証できるかの設計が要る。秘密鍵は、自動化のホストに置かない)。
- 別経路からの sha256 の検証。
- 四半期の災害復旧演習(全ノード消失からの再構築)。
