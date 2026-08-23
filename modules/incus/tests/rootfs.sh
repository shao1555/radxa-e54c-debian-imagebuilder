#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# incus モジュールの rootfs 検査
set -u
# shellcheck source=/dev/null
source "$E54C_TEST_LIB"

check "incus (実行可)" '^-rwx.* \./usr/bin/incus$'
# AppArmor: カーネル側の有効化だけでは不十分で、apparmor_parser が無いと
# incus が AppArmor サポートを無効化する
check "apparmor_parser (incus のコンテナ隔離に必要)" '^-rwx.* \./usr/sbin/apparmor_parser$'

exit "$fail"
