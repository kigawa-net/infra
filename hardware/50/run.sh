#!/usr/bin/env bash
# BWS_ACCESS_TOKEN が設定されている必要があります
set -euo pipefail

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
AWS_ACCESS_KEY_ID=$(bws secret get eb5eb0e8-2a4a-4398-a756-b37000d87d64 | jq -r '.value')
AWS_SECRET_ACCESS_KEY=$(bws secret get c39086cc-e112-40eb-b19f-b37000d89090 | jq -r '.value')

terraform "$@"