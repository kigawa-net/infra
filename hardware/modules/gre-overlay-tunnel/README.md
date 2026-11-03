# gre-overlay-tunnel

EasyTier のオーバーレイ(`10.250.0.0/24`、`tun0`)の**アドレスを両端にした GRE トンネル**を、1 ノードに張るモジュール。bao-02/03 と、Inuyama の control-plane(k8s4・k8s1・k8s2)の、どちらの側でも使う。設計: [`docs/frr-gre-overlay-design.md`](../../../docs/frr-gre-overlay-design.md)(§2 方式、§3 アドレス、§6 注意)。

**状態: 既定は無効。** 呼び出し側の `gre_overlay_enabled`(既定 `false`)が `true` のときだけ作る。このモジュールを入れても、BGP の neighbor は切り替えない(設計書 §7 の 3 以降)。

## 目的

EasyTier は、宛先が Overlay のアドレスのパケットしか運ばない。LAN 宛て(`10.0.0.0/24`、`192.168.1.0/24`)のパケットは、トンネルの中に入れれば、外側の宛先が Overlay のアドレスになるので、運ばれる。FRR が決めた next-hop(トンネル)どおりに届くようになる。

## 作られるもの

| 対象 | 内容 |
| --- | --- |
| `/usr/local/sbin/gre-overlay` | `files/gre-overlay-tunnel.sh` の複製。`up` / `down` を持つ |
| `/etc/gre-overlay/tunnels.conf` | 設定(`local`、`mtu`、`clamp_mss`、`firewall`、`peer` の各行) |
| `/etc/systemd/system/gre-overlay.service` | oneshot。`After=easytier.service`、`Wants=easytier.service`。`ExecStart` で `up`、`ExecStop` で `down` |
| `/etc/modules-load.d/gre-overlay.conf` | `ip_gre`(起動時に読み込む) |
| `gre-<name>` | 相手ごとの GRE トンネル。`ip tunnel add gre-<name> mode gre local <自分の Overlay> remote <相手の Overlay> ttl 64`、アドレスは `local_tunnel_cidr`(/31)、MTU は `mtu` |
| iptables(`clamp_mss = true`) | `mangle FORWARD -o gre+ -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu`。起動で入れ、停止で外す |
| ufw(`firewall = "ufw"`) | `tun0` から相手の Overlay の gre を許可(先頭に挿入)。`gre-<name>` から相手のトンネルの `179/tcp` を許可 |

`up` は冪等: 既にあるトンネルが、local と remote の両方とも設定どおりなら残す。食い違うときだけ消して作り直す。

## 変数

| 変数 | 既定 | 内容 |
| --- | --- | --- |
| `host` / `ssh_user` / `ssh_private_key` / `sudo_password` | (必須) | 接続。他のモジュールと同じ |
| `overlay_address` | (必須) | このノードの Overlay の IP(CIDR なし。例: `10.250.0.1`) |
| `peers` | (必須) | 相手のリスト。下の表 |
| `mtu` | `1300` | トンネルの MTU(576〜1336)。tun0 の MTU 1360 から GRE の 24 バイトを引いた値以下(§8) |
| `clamp_mss` | `false` | `true` で、TCP の MSS の clamp を入れる(control-plane 側で使う。§6.1) |
| `firewall` | `"none"` | `"ufw"` で、ufw の規則を入れる(bao 側で使う。§6.2) |

`peers` の各要素:

| フィールド | 例 | 内容 |
| --- | --- | --- |
| `name` | `"k8s4"` | 小文字英数字 1〜11 文字。インターフェース名は `gre-<name>`(15 文字以内) |
| `overlay_address` | `"10.250.0.11"` | 相手の Overlay の IP(GRE の remote) |
| `local_tunnel_cidr` | `"172.31.250.0/31"` | 自分側のトンネルのアドレス(/31) |
| `peer_tunnel_address` | `"172.31.250.1"` | 相手側のトンネルのアドレス(BGP の neighbor。同じ /31 のもう一方) |

## 適用

呼び出し側(`hardware/bao-02` など)で `gre_overlay_enabled = true` にして適用する。既定の `false` のままでは、このモジュールは何も作らない。

```bash
./hardware/run.sh bao-02 plan    # module.gre_overlay が 1 つ増えることを確認する
./hardware/run.sh bao-02 apply
```

適用後の確認(ノード上で):

```bash
systemctl status gre-overlay.service
ip -d link show type gre              # gre-<name> が local / remote を持つ。ttl 64、mtu 1300
ip -br addr show | grep gre-          # 172.31.250.x/31 が付いている
```

## 実機の確認の方法(設計書 §8 の手順の再現)

```bash
# 1. トンネル越しの疎通(トンネルのアドレス同士)。相手側のトンネルのアドレスへ ping
ping -c 3 -I gre-k8s4 172.31.250.1

# 2. EasyTier が GRE を運んでいるか(tun0 で、プロトコル 47 が両方向に見える)
tcpdump -ni tun0 proto 47

# 3. トンネルの MTU を越えるパケットが、分割なしで通るか(1272 バイト = 1300 - 28)
ping -c 2 -M do -s 1272 -I gre-k8s4 172.31.250.1
```

## 戻し方

1. 呼び出し側で `gre_overlay_enabled = false` にして適用する。`null_resource` は消えるが、ノード上のトンネルと unit は**自動では消えない**(この null_resource は、destroy で何もしない)。
2. ノードで停止し、無効化する: `systemctl disable --now gre-overlay.service`(`ExecStop` で、トンネルと MSS の規則が消える)。
3. `ufw` の規則を入れていた場合は、消す: `ufw status numbered` で番号を確認し、`ufw delete <番号>`(ufw の規則は外しても自動では消えない)。
4. 残った設定: `/etc/gre-overlay/`、`/usr/local/sbin/gre-overlay`、`/etc/systemd/system/gre-overlay.service`、`/etc/modules-load.d/gre-overlay.conf` は、手で消してよい。

## 注意

- `install` は `gre-overlay.service` を `restart` する。設定を変えたときは、停止(トンネルを消す)→ 起動(作り直す)になり、その間は GRE が切れる。BGP をトンネルに載せた後は、この順序に注意する。
- `ufw` の規則を作るときの、既にあるかの判定は、`ufw status` に出る印(コメント)を見ている。**inactive の ufw では規則が表示されないため、再実行のたびに規則が増える可能性がある**(未確認。ufw を有効にしてから使う)。
- `ip addr` は `replace` を使う(再実行で重複しない)。`ip tunnel add` は、食い違いがあるときだけ呼ぶ。

## 未確認(実機で確認が要る点)

- `ip tunnel add ... local <Overlay の IP>` が、起動時に `tun0` がまだ上がっていない状態で成功するか(unit は `After=easytier.service` だけに従う)。失敗するなら、`ExecStartPre` で待つ必要がある。
- ufw の `status` の表示形式(`# <コメント>` が行末に出るか)。
- 設計書 §8 の結果(MTU 1300、`ip_gre`、`rp_filter` 2)は、bao-02 と k8s1 の手動の確認の結果。この Terraform の構成そのものは、まだ適用していない。

## テスト

`bash hardware/modules/gre-overlay-tunnel/test-gre-overlay-tunnel.sh`(偽の `ip`・`iptables`・`ufw`・`modprobe`・`systemctl` を使う。実機には触れない)。install・up・down の冪等、食い違いの作り直し、MTU、MSS の clamp、ufw の規則、名前の長さ、不正な設定の拒否を確かめる。
