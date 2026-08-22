#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# k3s を静的バイナリとして導入する (deb が存在しないため)。
# $1 = rootfs のパス (bdebstrap の customize-hook から渡される)
set -euo pipefail
ROOT="$1"

# バージョンと SHA256 は必ずペアで更新する (renovate 等での自動更新を想定)。
# SHA256 は https://github.com/k3s-io/k3s/releases の sha256sum-arm64.txt に
# 記載の k3s-arm64 の値。検証はスキップ不可: 未設定ならビルドを失敗させる
K3S_VERSION="v1.36.3+k3s1"
K3S_SHA256="c9a209103f480f163b7c6a56f00862b4481927b284dc29a3716bb70d886691a8"

if [[ -z "$K3S_SHA256" || "$K3S_SHA256" == *PINNED* ]]; then
	echo "エラー: K3S_SHA256 が未設定 (チェックサム検証はスキップできない)" >&2
	exit 1
fi

curl -fL "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s-arm64" \
	-o "$ROOT/usr/local/bin/k3s"
echo "$K3S_SHA256  $ROOT/usr/local/bin/k3s" | sha256sum -c -
chmod 0755 "$ROOT/usr/local/bin/k3s"
for cmd in kubectl crictl ctr; do
	ln -sf k3s "$ROOT/usr/local/bin/$cmd"
done

# systemd unit (既定では無効。`systemctl enable k3s` で有効化する方針)
cat > "$ROOT/etc/systemd/system/k3s.service" <<'EOF'
[Unit]
Description=Lightweight Kubernetes (k3s)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/k3s server
KillMode=process
Delegate=yes
LimitNOFILE=1048576
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
