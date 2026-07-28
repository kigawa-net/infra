# kigawa-net/infra ionos ゲートウェイ設計書

**対象リポジトリ:** `kigawa-net/infra`
**対象拠点:** `ionos`
**設計方針:** [alice ゲートウェイ設計書](alice-gateway-design.md) と同一アーキテクチャ(WireGuard hub + FRR BGP + HAProxy)を、`alice` とは別拠点の独立した公開ゲートウェイとして並列に追加する。

`alice` を置き換えるものではなく、`alice` 障害時にも運用継続できる2本目の公開経路として位置づける。役割・公開ポート・Firewall方針は alice ゲートウェイ設計書と同一のため、本書では ionos 固有の差分のみを記載する。

---

## 1. alice との差分

| 項目                        | alice                        | ionos                         |
| --------------------------- | ----------------------------- | ------------------------------ |
| ホスト                      | `161.248.62.66`               | `74.208.55.86`                 |
| hostname                    | `alice-01`                    | `ionos-01`                     |
| BGP ASN                     | `65020`                       | `65030`                        |
| WireGuard hub アドレス      | `172.31.255.2/24`             | `172.31.254.2/24`              |
| inuyama gateway ピアアドレス | `172.31.255.1`                | `172.31.254.1`                 |
| k8s1 ピアアドレス           | `172.31.255.11`               | `172.31.254.11`                |
| k8s2 ピアアドレス           | `172.31.255.12`               | `172.31.254.12`                |
| Terraform module            | `hardware/alice`               | `hardware/ionos`                |
| sudo password Bitwarden ID  | `52b44d60-7cab-429f-929a-b4340139b6d8` | `070a1a26-0753-459e-9efd-b48e0079129f` |
| SSH鍵 Bitwarden ID          | `0393671f-6ef0-4650-be98-b364013f8644` (共用) | 同左(alice と共用) |

inuyama 側との WireGuard/BGP は alice と同様に hub-and-spoke 構成だが、**alice hub (`172.31.255.0/24`) と ionos hub (`172.31.254.0/24`) は別サブネット・別 WireGuard インターフェースとして扱う。** これにより、alice と ionos は互いに独立した障害ドメインとなる。

---

## 2. k8s1 / k8s2 側の追加ピア

`hardware/k8s1`, `hardware/k8s2` に `module "wireguard_ionos"` を追加済み(`hardware/modules/wireguard` を `wg1` インターフェースで2つ目のインスタンスとして呼び出す)。

- 制御変数: `wireguard_ionos_server_public_key` (デフォルト `""`)。alice 用の `wireguard_server_public_key` 同様、空文字の間はモジュールが作成されず無効のまま。
- ionos の `terraform apply` 実行後に `/etc/wireguard/ionos_public.key` の値を取得し、k8s1/k8s2 側の `wireguard_ionos_server_public_key` に設定して apply することで有効化する。
- k8s1/k8s2 の WireGuard 秘密鍵は wg0(alice向け)と wg1(ionos向け)で共有される(`hardware/modules/wireguard` が `/etc/wireguard/privatekey` を使い回す実装のため)。同一ホストの識別鍵を2つのhubに対して使う形になるが、WireGuard としては問題ない。

---

## 3. inuyama サイトゲートウェイ側(Terraform管理外・手動対応)

`inuyama` サイトゲートウェイは本リポジトリで Terraform 管理されていない(alice 側と同様、`inuyama_wireguard_*_bitwarden_id` 変数はIDを記録するのみで実体は読み取らない)。ionos を有効化するには、inuyama サイトゲートウェイ側で以下を手動追加する必要がある。

### 3.1 WireGuard

既存の `wg0`(alice 向け)とは別に、ionos 向けの WireGuard peer を追加する。既存 `wg0` に追加のアドレス・peer を足すか、新たに `wg1` インターフェースを立てるかは inuyama 側の実装に合わせて選択する。

```ini
# 追加アドレス (wg0 に追加する場合) もしくは新規 wg1 の [Interface] に設定
Address = 172.31.254.1/24

[Peer]
PublicKey = <ionos-public-key>   # /etc/wireguard/ionos_public.key (ionos apply後に取得)
AllowedIPs = 172.31.254.2/32
Endpoint = 74.208.55.86:51820
PersistentKeepalive = 25
```

### 3.2 BGP (FRR/Bird)

ASN `65030` の ionos と `172.31.254.1` <-> `172.31.254.2` でBGPピアを追加する。alice ピア(`neighbor 172.31.255.2 remote-as 65020`)と同様の設定を、ionos 用に追記する。

### 3.3 Firewall

alice と同じ方針(`179/tcp` は WireGuard内部のみ許可)を、ionos の WireGuard ピアアドレス(`172.31.254.1` <-> `172.31.254.2`)に対しても適用する。

---

## 4. HAProxy 転送先

ionos の HAProxy も alice と同じ inuyama backend VIP (`inuyama_ingress_vip` = `192.168.1.240`, `minecraft_backend_vip` = `192.168.1.241`) に転送する。DNS/GSLBでの alice・ionos 間の振り分け方針(Active-Active か Active-Standby か)は別途決定が必要。
