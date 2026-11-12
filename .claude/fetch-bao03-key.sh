#!/bin/bash
# bao-03 の SSH 鍵を /tmp/bao03_key に取り出す。画面には何も出さない。使い終わったら rm -f /tmp/bao03_key。
set -u
umask 077
rm -f /tmp/bao03_key
BWS_ACCESS_TOKEN=$(tr -d '\n' < "$HOME/dev/bws")
export BWS_ACCESS_TOKEN
bws secret get c10c4263-7cda-4e7d-b71c-b4f100118590 2>/dev/null | jq -r '.value' > /tmp/bao03_key 2>/dev/null
if [ -s /tmp/bao03_key ] && head -1 /tmp/bao03_key | grep -q 'BEGIN OPENSSH PRIVATE KEY'; then
  echo "OK: /tmp/bao03_key を作った"
else
  rm -f /tmp/bao03_key
  echo "NG: 鍵を取り出せなかった"
  exit 1
fi
