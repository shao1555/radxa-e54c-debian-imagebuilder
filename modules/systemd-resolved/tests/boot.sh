#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# systemd-resolved モジュールの boot 検査 (QEMU ゲスト内)
# shellcheck source=/dev/null
. "$E54C_BOOT_TEST_LIB"

chk "systemd-resolved 稼働" 'systemctl is-active systemd-resolved'
chk "resolv.conf が stub symlink" \
	'[ "$(readlink /etc/resolv.conf)" = ../run/systemd/resolve/stub-resolv.conf ]'
# 外部依存の検査は一時的な DNS 障害でリリースを落とさないようリトライする
chk "DNS 解決 (resolved スタブ経由)" \
	'timeout 60 sh -c "until getent hosts deb.debian.org; do sleep 3; done"'

exit "$fail"
