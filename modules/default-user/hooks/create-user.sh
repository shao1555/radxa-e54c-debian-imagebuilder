#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# 既定ユーザーの作成。$1 = rootfs のパス。
# 設定は framework が渡す解決済み config ($E54C_MODULE_CONFIG、この module の
# config だけを含む canonical JSON) から読む。
# 初期パスワードは secret ファイル (0600) から読む。環境変数名は framework が
# module ID / secret ID から決定的に生成する (docs/modules.md の符号化規則:
# E54C_SECRET_FILE_M<len>_<MODULE>_S<len>_<SECRET>)
set -euo pipefail
ROOT="$1"

username="$(python3 -c 'import json, os; print(json.load(open(os.environ["E54C_MODULE_CONFIG"]))["username"])')"
require_change="$(python3 -c 'import json, os; print(str(json.load(open(os.environ["E54C_MODULE_CONFIG"]))["requirePasswordChange"]).lower())')"

# default-user / initial-password の fileEnvironment (符号化規則より)
pw_file="${E54C_SECRET_FILE_M12_DEFAULT_USER_S16_INITIAL_PASSWORD:?secret file が渡されていない}"

# パスワード固有の形式検証はこの consumer が行う (framework は secret を
# opaque なバイト列として扱う)。chpasswd は行区切りで解釈するため
# 空・CR/LF を拒否する
password="$(cat "$pw_file")"
if [[ -z $password ]]; then
	echo "エラー: initial-password が空 (chpasswd に渡せない)" >&2
	exit 1
fi
if [[ $password == *$'\n'* || $password == *$'\r'* ]]; then
	echo "エラー: initial-password に改行 (CR/LF) を含めることはできません" >&2
	exit 1
fi

chroot "$ROOT" useradd -m -s /bin/bash -G sudo "$username"
# dash の echo は \n 等を解釈してしまうため、固定書式の printf を使う
printf '%s:%s\n' "$username" "$password" | chroot "$ROOT" chpasswd
if [[ $require_change == true ]]; then
	# 初期パスワードは周知の値になり得るため、初回ログイン時に変更を強制する
	chroot "$ROOT" chage -d 0 "$username"
fi
