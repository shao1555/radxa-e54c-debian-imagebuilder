#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# default-user モジュールの rootfs 検査。
# 対象ユーザー名等は解決済み config ($E54C_MODULE_CONFIG) から読む
# (hard-coded な "debian" を前提にしない)
set -u
# shellcheck source=/dev/null
source "$E54C_TEST_LIB"

username="$(python3 -c 'import json, os; print(json.load(open(os.environ["E54C_MODULE_CONFIG"]))["username"])')"
require_change="$(python3 -c 'import json, os; print(str(json.load(open(os.environ["E54C_MODULE_CONFIG"]))["requirePasswordChange"]).lower())')"

# login(1): 欠けるとシリアルコンソールからログイン不能になる
check "login バイナリ (シリアルログインに必要)" '^-rwx.* \./usr/bin/login$'

if tar_cat ./etc/passwd | grep -qE "^${username}:x:[0-9]+:[0-9]+:.*:/home/${username}:/bin/bash$"; then
	echo "ok: ${username} ユーザーが存在"
else
	echo "NG: ${username} ユーザーが存在しない"
	fail=1
fi
shadow_line="$(tar_cat ./etc/shadow | grep "^${username}:" || true)"
shadow_field="$(cut -d: -f2 <<< "$shadow_line")"
if [[ $shadow_field == \$* ]]; then
	echo "ok: ${username} のパスワードが設定済み (ロックされていない)"
else
	echo "NG: ${username} のパスワードが未設定またはロック (shadow: ${shadow_field:0:2}...)"
	fail=1
fi
lastchg="$(cut -d: -f3 <<< "$shadow_line")"
if [[ $require_change == true ]]; then
	if [[ $lastchg == "0" ]]; then
		echo "ok: 初回ログイン時のパスワード変更が強制される (lastchg=0)"
	else
		echo "NG: パスワード変更の強制が無い (chage -d 0 が消えている)"
		fail=1
	fi
else
	if [[ $lastchg != "0" ]]; then
		echo "ok: パスワード変更の強制なし (requirePasswordChange: false の設定どおり)"
	else
		echo "NG: requirePasswordChange: false なのに lastchg=0"
		fail=1
	fi
fi
if tar_cat ./etc/group | grep -qE "^sudo:.*[:,]${username}(,|$)"; then
	echo "ok: ${username} が sudo グループに所属"
else
	echo "NG: ${username} が sudo グループに所属していない"
	fail=1
fi

exit "$fail"
