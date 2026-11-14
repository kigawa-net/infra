# EasyTier Secure Mode の有効化: 検証済みの事実と、移行の設計

2026-11-14。#503(Secure Mode を全ノードで有効化)が、全ノードのオーバーレイを落とした(2026-11-13 02:48 UTC〜)。その反省として、**手元で、EasyTier 2.6.4 の挙動を実測**してから、設計した。
実験は `hardware/modules/easytier/experiment-secure-mode.sh`(再現できる。約 2 分。12 項目、すべて OK)。

## 1. 検証済みの事実(EasyTier 2.6.4)

| # | 事実 | 意味 |
|---|---|---|
| E1 | secure 同士(`network_secret` あり、鍵は自動生成)は、**credential なし**で接続できる | ノード同士の接続に、credential は要らない |
| E2・E3 | **secure と非 secure の混在は、どちらの向きでも接続できない**(`handshake response` のエラー)| ノードを 1 台ずつ切り替えると、オーバーレイが分断される。#503 の障害の原因 |
| E4・E5 | credential(`easytier-cli credential generate --ttl <秒>`)で、**`network_secret` なし**で参加できる。`revoke` で、すぐ切れる | ノードごとに、失効できる鍵を持たせられる |
| E6 | 違う `network_secret` は、拒否される | |
| **E7** | **正しい `network_secret` を知る者は、secure mode でも、credential なしで参加できる** | **secure mode を有効にしても、`network_secret` の漏洩は、防げない**。#503 の目的(「secret が漏れても、credential がなければ参加できない」)は、フラグを立てるだけでは、達成されない |
| E8 | 10 年の TTL を受け付ける。`--credential-file` で、admin を再起動しても、credential が残る | 長寿のノードにも、使える |
| E9 | credential のノードは、別の **credential のノード**(`--allow-relay` でも)を経由して、参加できない | ハブ(公開ノード)は、`network_secret` を持つノードにすること |
| E10〜E13 | `network_secret` を持つハブが **2 台以上**あれば、片方が落ちても、credential のノードは残り、再起動もできる。ハブが 1 台だけだと、その 1 台が落ちたとき、全員が切れる | ハブは 2 台以上にする(単一障害点) |
| E15 | credential のノード同士は、ハブ経由で、お互いが見える | |
| E16 | 同じ credential を、複数台で使い回せる(`--reusable true`) | |

## 2. #503 の何が誤りだったか
- 「credential を発行して配布してから、再起動」という手順は、**ノード同士の接続には、不要**だった(E1)。一方、**混在の状態で、1 台ずつ切り替える**手順は、オーバーレイを分断した(E2・E3)。
- 目的の「secret の漏洩対策」は、secure mode だけでは、達成されない(E7)。
- 影響: オーバーレイが落ちて、BGP の一部(オーバーレイ側の隣接)と、CI の経路が止まった。ionos から `10.0.0.240` への経路は、WireGuard(`wg-gw*`)経由なので、サイトは、止まらなかった。

## 3. 選択肢

| 案 | 内容 | 得られるもの | 費用・リスク |
|---|---|---|---|
| A. 有効にしない(**現状**) | secure mode 無効、`network_secret` を共有 | なし | `network_secret` が、6 ノードと、Terraform の state、bws に散らばる。漏れたら、誰でも参加できる |
| B. 全ノードを secure(secret 共有) | 全ノード同時に、`secure_mode_enabled = true` | ノード間の通信が、ノードごとの鍵で、認証・暗号化される(E1) | **混在できないので、全ノードを同時に切り替える**(分断の窓)。漏洩対策には、ならない(E7) |
| **C. ハブ = secret、エッジ = credential(推奨)** | 公開ノード(bao-02、bao-03、ionos)だけが、`network_secret` を持つ。k8s1・k8s2・k8s4・CI のランナーは、ノードごとの credential で参加する | `network_secret` の置き場が、**3 ノード**に減る。エッジの鍵は、**ノードごとに失効できる**。CI のランナーは、短い TTL の credential にできる | 移行の窓(分断)がある。ハブの全断で、エッジが全員切れる(E10)。credential の TTL の失効日の運用 |

**推奨は C。ただし、効果は限定的**(E7: ハブの `network_secret` が漏れれば、参加される)。得られる主な価値は、(1) エッジのノードの鍵を失効できること、(2) CI のランナーが、`network_secret` を持たずに済むこと。
効果が、移行のリスクに見合わなければ、**A のままでよい**。

## 4. 推奨(案 C)の設計

- **ハブ**(`network_secret` + secure): bao-02、bao-03、ionos。**3 台**(E10〜E13)。bao-02 が credential の発行ノード(`credential_file` を持つ)。
- **エッジ**(credential + secure。`network_secret` なし): k8s1、k8s2、k8s4。接続先(peer)は、ハブだけ(E9)。
- **CI のランナー**: 専用の credential(`--ttl` を短く。例: 1 日、`--reusable true`)。GitHub のシークレットに置く。失効は、`credential revoke`。
- **credential の保管**: bws に、ノードごとのシークレット(`easytier-credential-<ノード名>`)。Terraform から読む。TTL は 10 年(E8)にし、**失効日を、カレンダー(と、docs)に書く**。
- **発行の安全**: 発行は、bao-02 の `easytier-cli credential generate` で行い、値を、bws に直接入れる(画面に出さない)。

## 5. 移行手順(案 C)

**前提(必ず先に)**: 
1. 外部の経路の連続測定(`docs/ingress-routing.md` の `curl --resolve`)を、基準として取る。
2. 現状の設定ファイル(`/etc/easytier/easytier.toml`)のバックアップを、各ノードで取る。
3. 「分断の窓」で、何が止まるかを、確認する: オーバーレイ側の BGP 隣接(bao ↔ k8s4)、GRE、CI の EasyTier 経路(無効のため、影響なし)。**サイト(Cloudflare → ionos → WireGuard → ingress)は、止まらない**(2026-11-13 の #503 で、実測済み)。
4. 時間帯: 利用の少ない時間。

**手順**:
1. **ハブ 3 台を、同時に secure に切り替える**(bao-02、bao-03、ionos。`secure_mode_enabled = true`、bao-02 に `credential_file`)。エッジは、まだ非 secure なので、ハブから切れる(E3)。エッジ同士(k8s1・k8s2・k8s4)は、非 secure のまま、つながっている。
2. bao-02 で、credential を発行する(k8s1、k8s2、k8s4、CI のランナー)。bws に保存する。
3. **エッジを 1 台ずつ**、`network_secret` を外して、credential に切り替える(`--credential`、`--secure-mode`)。エッジ同士は、混在するので、**エッジ 3 台も、同時に切り替える**(E2・E3)。k8s4 は、BGP のルーターなので、最後ではなく、3 台同時が望ましい。
4. 確認: 全ノードが、`easytier-cli peer` で見える。BGP のオーバーレイ隣接が、`Established`。外部の経路が、302 のまま。
5. 戻し方: 各ノードの設定ファイルのバックアップに戻して、`easytier` を再起動(全ノード同時)。

**やってはいけないこと**: 1 台ずつ、順番に切り替える(混在で、分断される。E2・E3)。`network_secret` を持たないハブを作る(E9)。ハブを 1 台にする(E10)。

## 6. 検証してから、進める
- 手元の実験(`experiment-secure-mode.sh`)で、設計の前提を、確認済み。実機(本番)での検証は、**まだしていない**。
- 本番で試す前に、(a) EasyTier を、同じバージョン(2.6.4)に固定、(b) テスト用の別のオーバーレイ(`network_name` が別)を、bao-02 と ionos と、1 台のエッジで、立てて、案 C を通しで試す、ことを勧める。
- **今日の教訓**: 経路を変える変更は、外部の経路で、連続して測ってから、本番に入れる(`docs/ingress-routing.md`)。
