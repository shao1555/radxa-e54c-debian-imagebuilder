#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# SSH モジュールの rootfs 検査 (rootfs.tar への静的検査)
set -u
# shellcheck source=/dev/null
source "$E54C_TEST_LIB"

enabled "ssh が enable" 'multi-user\.target\.wants/ssh\.service' 'ssh\.service'
# ホスト鍵は焼き込み禁止 (全端末で同一鍵になる)。初回起動時の生成は
# trixie 標準の sshd-keygen.service (ConditionFirstBoot) に任せている
check_absent "SSH ホスト鍵が焼き込まれていない" '\./etc/ssh/ssh_host_'
check "sshd-keygen.service が ssh.service に配線" \
	'^l.* \./etc/systemd/system/ssh\.service\.wants/sshd-keygen\.service -> /usr/lib/systemd/system/sshd-keygen\.service$'
check "sshd 設定 (PasswordAuthentication 切替用)" '^-.* \./etc/ssh/sshd_config\.d/10-e54c-server\.conf$'
# 成果物の要件は「debian/debian で SSH ログインできる」なので yes を要求する
# (no への切替は各端末上で行う想定。ビルド段階で no になっていたら
#  ログイン手段を失った成果物なので落とす)
if tar_cat ./etc/ssh/sshd_config.d/10-e54c-server.conf \
	| grep -qE '^PasswordAuthentication yes$'; then
	echo "ok: sshd がパスワード認証を受け付ける (PasswordAuthentication yes)"
else
	echo "NG: PasswordAuthentication yes が無い (成果物にログイン手段が無い)"
	fail=1
fi

exit "$fail"
