#!/bin/bash
# bao-02 側の GRE テストを、手元から実行する。鍵は /tmp/bao02_key(fetch-bao02-key.sh で作る)。
# 使い方: bash gre-test-bao02.sh <up|down|status>
here=$(cd "$(dirname "$0")" && pwd)
[ -s /tmp/bao02_key ] || { echo "NG: /tmp/bao02_key が無い。先に fetch-bao02-key.sh"; exit 1; }
ssh -i /tmp/bao02_key -o IdentitiesOnly=yes root@207.231.111.196 bash -s "${1:-status}" bao02 < "$here/gre-test-side.sh"
