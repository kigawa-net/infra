#!/bin/bash
# bao-02 の SSH 鍵を /tmp/bao02_key に取り出す。画面には何も出さない(エラーも抑える)。使い終わったら rm -f /tmp/bao02_key。
set -u
umask 077
rm -f /tmp/bao02_key
BWS_ACCESS_TOKEN=$(tr -d '\n' < "$HOME/dev/bws")
export BWS_ACCESS_TOKEN
bws secret get 826652fb-c615-4fe1-88c3-b4f000bf1f37 2>/dev/null | jq -r '.value' > /tmp/bao02_key 2>/dev/null
if [ -s /tmp/bao02_key ] && head -1 /tmp/bao02_key | grep -q 'BEGIN OPENSSH PRIVATE KEY'; then
  echo "OK: /tmp/bao02_key を作った"
else
  rm -f /tmp/bao02_key
  echo "NG: 鍵を取り出せなかった"
  exit 1
fi
