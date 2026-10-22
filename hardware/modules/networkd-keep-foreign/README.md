# networkd-keep-foreign

`systemd-networkd` が、**自分の管理外のポリシールール(`ip rule`)と経路を、起動・再起動のたびに消さない**ようにする drop-in(`/etc/systemd/networkd.conf.d/10-keep-foreign.conf`)を置く module。

```ini
[Network]
ManageForeignRoutingPolicyRules=no
ManageForeignRoutes=no
```

## 背景(kigawa-net/infra#238)
`systemd-networkd` は、既定(`yes`)で、wg-quick の `PostUp`、FRR(zebra)、手動で入れた `ip rule` と経路を、再起動のたびに消す。
**2026-10-21 06:21 UTC、k8s2 の networkd が、パッケージの更新に伴って再起動され、`wg1` の `PostUp` で入れたポリシールール(`ip rule from 10.0.0.0/24 to 172.31.254.2/32 lookup 200`。#282)と、`table 200` の経路が消えた。** IONOS から API の VIP(k8s2 が保持)と `10.0.0.120` に届かなくなった(復旧: ルールの再投入)。k8s1 は 06:44 に再起動、**k8s4 は、最後の起動が 10/18 のままで、次の再起動で同じ目に遭う**。

## 挙動
- **networkd は再起動しない。** 再起動すると、今ある外部のルール・経路が消える可能性があり、CI の SSH 経路も切れうる。設定は、**次に networkd が起動するとき**(ノードの再起動、パッケージの更新による再起動)から効く。
- 冪等(内容が同じなら、何もしない)。
- k8s1・k8s2・k8s4 から呼ぶ。

## テスト
`bash hardware/modules/wg-conf-table-off/test-wg-conf-table-off.sh`(`wg-conf-table-off` と共通)。
