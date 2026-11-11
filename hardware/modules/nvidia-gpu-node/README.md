# nvidia-gpu-node

NVIDIA ドライバの導入(#302)。Container Toolkit と containerd の設定は、クラスタの gpu-operator が行うため既定では入れない(`install_container_toolkit = true` で、このモジュールが入れる)。設計は `docs/gpu-node-design.md`。

既定は `enabled = false`(何もしない)。適用手順(稼働中ノードなので手動):

1. `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`
2. `enabled = true` にして `./hardware/run.sh <module> apply`
3. ノードを再起動し、`nvidia-smi` で GPU と VRAM を確認
4. `kubectl uncordon <node>`

`driver_package` は GPU 世代に合わせる(`apt-cache policy` で確認)。Kepler の worker3 は本モジュールを使わず 470 固定のまま。
