#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# default-user モジュールの rootfs 検査
set -u
# shellcheck source=/dev/null
source "$E54C_TEST_LIB"

# login(1): 欠けるとシリアルコンソールからログイン不能になる
check "login バイナリ (シリアルログインに必要)" '^-rwx.* \./usr/bin/login$'

if tar_cat ./etc/passwd | grep -qE '^debian:x:[0-9]+:[0-9]+:.*:/home/debian:/bin/bash$'; then
	echo "ok: debian ユーザーが存在"
else
	echo "NG: debian ユーザーが存在しない"
	fail=1
fi
shadow_line="$(tar_cat ./etc/shadow | grep '^debian:' || true)"
shadow_field="$(cut -d: -f2 <<< "$shadow_line")"
if [[ $shadow_field == \$* ]]; then
	echo "ok: debian のパスワードが設定済み (ロックされていない)"
else
	echo "NG: debian のパスワードが未設定またはロック (shadow: ${shadow_field:0:2}...)"
	fail=1
fi
# 既知の初期パスワードのまま運用されないよう、初回ログイン時の変更強制
# (chage -d 0 = shadow の第 3 フィールドが 0) を要求する
if [[ "$(cut -d: -f3 <<< "$shadow_line")" == "0" ]]; then
	echo "ok: 初回ログイン時のパスワード変更が強制される (lastchg=0)"
else
	echo "NG: パスワード変更の強制が無い (chage -d 0 が消えている)"
	fail=1
fi
if tar_cat ./etc/group | grep -qE '^sudo:.*[:,]debian(,|$)'; then
	echo "ok: debian が sudo グループに所属"
else
	echo "NG: debian が sudo グループに所属していない"
	fail=1
fi

exit "$fail"
