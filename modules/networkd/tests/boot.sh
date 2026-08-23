#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# networkd モジュールの boot 検査 (QEMU ゲスト内)
# shellcheck source=/dev/null
. "$E54C_BOOT_TEST_LIB"

chk "systemd-networkd 稼働" 'systemctl is-active systemd-networkd'
chk "DHCP で IPv4 取得 (networkd)" \
	'timeout 60 sh -c "until ip -4 addr show scope global | grep -q dynamic; do sleep 2; done"'
chk "デフォルト経路がある" 'ip route | grep -q ^default'

exit "$fail"
