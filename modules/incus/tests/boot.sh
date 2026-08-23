#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# incus モジュールの boot 検査 (QEMU ゲスト内)
# shellcheck source=/dev/null
. "$E54C_BOOT_TEST_LIB"

# AppArmor の実動作 (カーネル LSM として有効か)。パッケージ・userspace と
# 合わせて incus モジュールが所有する
chk "AppArmor 有効 (カーネル LSM)" '[ "$(cat /sys/module/apparmor/parameters/enabled)" = Y ]'

# incus は socket activation のため、応答するまでリトライしてから検査する
chk "incus が応答" 'timeout 180 sh -c "until incus info >/dev/null 2>&1; do sleep 5; done"'
# incusd は AppArmor を利用できないとき起動ログに warn を出す。それが無いこと
# を確認する (incus info の出力には apparmor の項が無く、直接は判定できない)
chk "incus の AppArmor サポートが無効化されていない" \
	'! journalctl -u incus --no-pager 2>/dev/null | grep -qi "apparmor support has been disabled"'

exit "$fail"
