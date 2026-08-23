#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# k3s を静的バイナリとして導入する (deb が存在しないため)。
# $1 = rootfs のパス (bdebstrap の customize-hook から渡される)
set -euo pipefail
ROOT="$1"

# バージョン・URL・SHA256 は dependencies.lock.yaml で一元管理する (Issue #4)。
# 必ずペアで更新する (renovate 等での自動更新を想定)。
# SHA256 は https://github.com/k3s-io/k3s/releases の sha256sum-arm64.txt に
# 記載の k3s-arm64 の値。検証はスキップ不可: 取得できなければビルドを失敗させる
TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
K3S_URL="$(python3 "$TOP/scripts/lock-get.py" k3s.url)"
K3S_SHA256="$(python3 "$TOP/scripts/lock-get.py" k3s.sha256)"

if [[ -z "$K3S_SHA256" ]]; then
	echo "エラー: k3s.sha256 が lock に無い (チェックサム検証はスキップできない)" >&2
	exit 1
fi

# 一時的なネットワーク障害に備えてリトライする (完全性は sha256 検証が担保)
curl -fL --retry 5 --retry-all-errors --retry-delay 10 \
	"$K3S_URL" -o "$ROOT/usr/local/bin/k3s"
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
