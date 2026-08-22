#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# k3s を静的バイナリとして導入する (deb が存在しないため)。
# $1 = rootfs のパス (bdebstrap の customize-hook から渡される)
set -euo pipefail
ROOT="$1"

K3S_VERSION="v1.36.3+k3s1"
K3S_SHA256="__PINNED_SHA256__"  # renovate 等でバージョンと共に更新する

curl -fL "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s-arm64" \
	-o "$ROOT/usr/local/bin/k3s"
if [[ "$K3S_SHA256" != "__PINNED_SHA256__" ]]; then
	echo "$K3S_SHA256  $ROOT/usr/local/bin/k3s" | sha256sum -c -
fi
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
