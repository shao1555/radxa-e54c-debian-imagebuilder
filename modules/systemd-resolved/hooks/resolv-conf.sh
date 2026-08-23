#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# /etc/resolv.conf を resolved の stub への symlink にする (rootfs.seal)。
# $1 = rootfs のパス。
# ビルドホストの DNS 設定 (mmdebstrap が入れる resolv.conf) を除去して
# 張り替える。単に削除するだけだと初回起動時に glibc が /etc/resolv.conf を
# 見つけられず DNS 解決が壊れる
set -euo pipefail
rm -f "$1/etc/resolv.conf"
ln -s ../run/systemd/resolve/stub-resolv.conf "$1/etc/resolv.conf"
