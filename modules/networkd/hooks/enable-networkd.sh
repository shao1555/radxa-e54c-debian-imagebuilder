#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# systemd-networkd の有効化。$1 = rootfs のパス
set -euo pipefail
chroot "$1" systemctl enable systemd-networkd.service systemd-networkd.socket
