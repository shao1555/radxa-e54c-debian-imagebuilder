#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# SSH モジュールの boot 検査 (QEMU ゲスト内で root として実行される)
# shellcheck source=/dev/null
. "$E54C_BOOT_TEST_LIB"

chk "sshd 稼働" 'systemctl is-active ssh'

exit "$fail"
