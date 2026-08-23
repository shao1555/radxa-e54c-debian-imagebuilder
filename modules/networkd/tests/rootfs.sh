#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# networkd モジュールの rootfs 検査
set -u
# shellcheck source=/dev/null
source "$E54C_TEST_LIB"

enabled "systemd-networkd が enable"        'multi-user\.target\.wants/systemd-networkd\.service' 'systemd-networkd\.service'
enabled "systemd-networkd.socket が enable" 'sockets\.target\.wants/systemd-networkd\.socket'     'systemd-networkd\.socket'
check "lan1 の .network 設定" '\./etc/systemd/network/10-lan1\.network$'
check "wait-online の drop-in (--any --timeout)" \
	'\./etc/systemd/system/systemd-networkd-wait-online\.service\.d/override\.conf$'

exit "$fail"
