#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# k3s モジュールの boot 検査 (QEMU ゲスト内)
# shellcheck source=/dev/null
. "$E54C_BOOT_TEST_LIB"

chk "k3s バイナリ実行可" 'k3s --version'
# 「既定では無効」の設計。preset による disable 固定が初回ブートでも
# 効いていることを実測する
chk "k3s が enable されていない" '[ "$(systemctl is-enabled k3s)" = disabled ]'
chk "k3s が起動していない" '[ "$(systemctl is-active k3s)" = inactive ]'

exit "$fail"
