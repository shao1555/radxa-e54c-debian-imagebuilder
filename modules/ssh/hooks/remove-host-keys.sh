#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ビルド時に生成された SSH ホスト鍵を成果物から除去する (rootfs.seal)。
# $1 = rootfs のパス
set -euo pipefail
rm -f "$1/etc/ssh/ssh_host_"*
