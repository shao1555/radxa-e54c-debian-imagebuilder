#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# k3s モジュールの rootfs 検査
set -u
# shellcheck source=/dev/null
source "$E54C_TEST_LIB"

check "k3s バイナリ (実行可)" '^-rwx.* \./usr/local/bin/k3s$'
check "k3s の systemd unit"   '^-.* \./etc/systemd/system/k3s\.service$'
# k3s は「既定では無効」。初回ブートの preset-all (Debian 既定 enable *) が
# 勝手に enable して restart ループする回帰を踏んだため、preset ファイルで固定する
check "k3s を disable する preset" '^-.* \./etc/systemd/system-preset/50-k3s\.preset$'
check_absent "k3s が enable されていない" \
	'\./etc/systemd/system/multi-user\.target\.wants/k3s\.service'

exit "$fail"
