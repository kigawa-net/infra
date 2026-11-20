# latte-dev.kigawa.net の A レコードの drift 検知 (#528)
#
# 背景: Terraform の state 外に 192.168.1.242 (LAN IP) の A レコードが残り、
#       DNS ラウンドロビンで外部クライアントの約半数が失敗した。
#       cloudflare_record.latte_dev は allow_overwrite で 1 件を管理するだけで、
#       同名の「余計な」レコードは検知できない。そこで、Cloudflare 上の実際のレコードを
#       data ソースで読み、期待値と比較する。
#
# 期待値: A レコードがちょうど 1 件、content = 74.208.55.86 (ionos)、proxied = false
#
# 仕組み:
#   - check ブロックの assertion が失敗すると、plan / apply に警告 (Warning) が出る。
#     check はエラーにならないので、drift があっても plan / apply 自体は止まらない
#     (drift を直す apply を、この検知が妨げないため)。
#   - 警告のメッセージに、実際のレコード一覧 (content, proxied, id) を載せる。
#   - output "drift" は apply 後は `terraform output -json drift` で取れる。
#     cloudflare-apply.yml が、plan の後に step summary へ出力する。
#
# 対処法: 余計なレコードは Cloudflare の UI (DNS > Records) で、id を確認して削除する。
#         Terraform 管理のレコード (74.208.55.86) は消さない。
#         content や proxied が違う場合は、Terraform の apply で直る。
#
# 注意: output は apply 後の state にしか入らない。apply 前 (PR の plan) の値は
#       `terraform show -json tfplan | jq .planned_values.outputs.drift.value` で取れる
#       (cloudflare-apply.yml はこちらを使う)。

locals {
  latte_dev_expected_content = "74.208.55.86"
  latte_dev_expected_proxied = false
}

# provider v4 (4.52) には、同名の複数レコードを返す data ソースが無い
# (cloudflare_record は 1 件固定、v5 の cloudflare_dns_records は使えない)。
# そのため、Cloudflare API を直接呼ぶ。トークンは main.tf の data.external.api_token と同じもの。
# name.exact で FQDN を完全一致にする。per_page=100 で 1 ページに収める(同名 A が 100 件を超えることは無い)。
data "external" "latte_dev_records" {
  program = ["bash", "-c", <<-EOT
    set -euo pipefail
    query=$(cat)
    token=$(jq -r .token <<<"$query")
    zone_id=$(jq -r .zone_id <<<"$query")
    resp=$(curl -fsS --retry 3 --retry-all-errors --max-time 30 \
      -H "Authorization: Bearer $token" \
      "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name.exact=latte-dev.kigawa.net&per_page=100")
    jq -e '.success == true' <<<"$resp" >/dev/null || { echo "Cloudflare API error" >&2; exit 1; }
    jq -c '{records: ([.result[] | {id, name, content, proxied}] | tojson)}' <<<"$resp"
  EOT
  ]
  query = {
    token   = data.external.api_token.result.value
    zone_id = var.zone_id
  }
}

locals {
  latte_dev_records = jsondecode(data.external.latte_dev_records.result.records)

  latte_dev_unexpected = [
    for r in local.latte_dev_records : r
    if r.content != local.latte_dev_expected_content || r.proxied != local.latte_dev_expected_proxied
  ]

  latte_dev_drift = length(local.latte_dev_records) != 1 || length(local.latte_dev_unexpected) > 0

  latte_dev_records_text = join(", ", [
    for r in local.latte_dev_records : "{id=${r.id}, content=${r.content}, proxied=${r.proxied}}"
  ])
}

check "latte_dev_a_record_drift" {
  assert {
    condition     = length(local.latte_dev_records) == 1
    error_message = "latte-dev.kigawa.net の A レコードが ${length(local.latte_dev_records)} 件ある (期待: 1 件)。Cloudflare の UI で余計なレコードを削除すること。レコード一覧: [${local.latte_dev_records_text}]"
  }

  assert {
    condition     = alltrue([for r in local.latte_dev_records : r.content == local.latte_dev_expected_content])
    error_message = "latte-dev.kigawa.net の A レコードに content が ${local.latte_dev_expected_content} でないものがある。レコード一覧: [${local.latte_dev_records_text}]"
  }

  assert {
    condition     = alltrue([for r in local.latte_dev_records : r.proxied == local.latte_dev_expected_proxied])
    error_message = "latte-dev.kigawa.net の A レコードに proxied が ${local.latte_dev_expected_proxied} でないものがある。レコード一覧: [${local.latte_dev_records_text}]"
  }
}

output "drift" {
  description = "latte-dev.kigawa.net の A レコードの drift 検知結果"
  value = {
    drift             = local.latte_dev_drift
    expected_content  = local.latte_dev_expected_content
    expected_proxied  = local.latte_dev_expected_proxied
    records           = local.latte_dev_records
    unexpected_record = local.latte_dev_unexpected
  }
}
