#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# rootfs.tar の回帰検査。tar の listing (+一部ファイル抽出) だけで検査するため、
# ビルド環境 (devcontainer) 不要でホスト/CI ランナーのどちらでも実行できる。
# 過去に実際に踏んだ回帰 (networkd 未 enable、resolv.conf 消失、
# カーネル未投入など) を最低ラインとして検査する。
set -euo pipefail

cd "$(dirname "$0")/.."
TAR="${1:-out/rootfs/build/rootfs.tar}"
[[ -f $TAR ]] || { echo "NG: rootfs.tar が無い: $TAR" >&2; exit 1; }

listing="$(tar -tvf "$TAR")"
fail=0

check() { # <説明> <grep -E パターン>
	if grep -qE "$2" <<< "$listing"; then
		echo "ok: $1"
	else
		echo "NG: $1 (pattern: $2)"
		fail=1
	fi
}

check_absent() { # <説明> <grep -E パターン>
	if grep -qE "$2" <<< "$listing"; then
		echo "NG: $1 (存在してはいけない)"
		fail=1
	else
		echo "ok: $1"
	fi
}

# --- ネットワーク (初回起動で SSH 到達できること) ---
# enable 判定はフルパス + symlink 種別 + リンク先まで厳密に照合する。
# パス末尾だけの照合だと var/lib/systemd/deb-systemd-helper-enabled/ 配下の
# metadata に誤一致し、本命の /etc/systemd/system/ の symlink 欠落を見逃す
enabled() { # <説明> <wants 配下の相対パス> <リンク先ユニット>
	check "$1" "^l.* \\./etc/systemd/system/$2 -> /usr/lib/systemd/system/$3\$"
}
enabled "systemd-networkd が enable"        'multi-user\.target\.wants/systemd-networkd\.service' 'systemd-networkd\.service'
enabled "systemd-networkd.socket が enable" 'sockets\.target\.wants/systemd-networkd\.socket'     'systemd-networkd\.socket'
enabled "systemd-resolved が enable"        'sysinit\.target\.wants/systemd-resolved\.service'    'systemd-resolved\.service'
enabled "ssh が enable"                     'multi-user\.target\.wants/ssh\.service'              'ssh\.service'
# SSH: ホスト鍵は焼き込み禁止 (全端末で同一鍵になる)。初回起動時の生成は
# trixie 標準の sshd-keygen.service (ConditionFirstBoot) に任せている
check_absent "SSH ホスト鍵が焼き込まれていない" '\./etc/ssh/ssh_host_'
check "sshd-keygen.service が ssh.service に配線" \
	'^l.* \./etc/systemd/system/ssh\.service\.wants/sshd-keygen\.service -> /usr/lib/systemd/system/sshd-keygen\.service$'
check "sshd 設定 (PasswordAuthentication 切替用)" '^-.* \./etc/ssh/sshd_config\.d/10-e54c-server\.conf$'
# 成果物の要件は「debian/debian で SSH ログインできる」なので yes を要求する
# (no への切替は各端末上で行う想定。ビルド段階で no になっていたら
#  ログイン手段を失った成果物なので落とす)
if tar -xOf "$TAR" ./etc/ssh/sshd_config.d/10-e54c-server.conf 2> /dev/null \
	| grep -qE '^PasswordAuthentication yes$'; then
	echo "ok: sshd がパスワード認証を受け付ける (PasswordAuthentication yes)"
else
	echo "NG: PasswordAuthentication yes が無い (成果物にログイン手段が無い)"
	fail=1
fi
# デフォルトユーザー: 存在 + ロックされていない (shadow がハッシュ) + sudo 所属
if tar -xOf "$TAR" ./etc/passwd 2> /dev/null | grep -qE '^debian:x:[0-9]+:[0-9]+:.*:/home/debian:/bin/bash$'; then
	echo "ok: debian ユーザーが存在"
else
	echo "NG: debian ユーザーが存在しない"
	fail=1
fi
shadow_line="$(tar -xOf "$TAR" ./etc/shadow 2> /dev/null | grep '^debian:')"
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
if tar -xOf "$TAR" ./etc/group 2> /dev/null | grep -qE '^sudo:.*[:,]debian(,|$)'; then
	echo "ok: debian が sudo グループに所属"
else
	echo "NG: debian が sudo グループに所属していない"
	fail=1
fi
check "resolv.conf が resolved の stub へ symlink" \
	'^l.* \./etc/resolv\.conf -> \.\./run/systemd/resolve/stub-resolv\.conf$'
check_absent "ビルドホスト DNS の漏洩 (.resolv.conf.systemd-resolved.bak)" \
	'\./etc/\.resolv\.conf\.systemd-resolved\.bak$'
check "lan1 の .network 設定"             '\./etc/systemd/network/10-lan1\.network$'

# --- ブート (カーネル・DTB・extlinux) ---
# 通常ファイルも「^-(種別) + フルパス + 行末 $」で固定し、.bak/.old 等への
# 誤一致を防ぐ。実行が必要なものは実行ビット (^-rwx) まで確認する
check "カーネル (vmlinuz)"                 '^-.* \./boot/vmlinuz-[0-9][^ ]*$'
check "initrd"                             '^-.* \./boot/initrd\.img-[0-9][^ ]*$'
check "E54C の DTB"                        '^-.* \./usr/lib/linux-image-[^ ]*/rockchip/rk3582-radxa-e54c\.dtb$'
check "extlinux.conf (u-boot-update 生成)" '^-.* \./boot/extlinux/extlinux\.conf$'
check "/etc/kernel/cmdline"                '^-.* \./etc/kernel/cmdline$'
check "U-Boot 書き込みスクリプト (実行可)" '^-rwx.* \./usr/lib/u-boot/radxa-e54c/setup\.sh$'

# --- コンテナ基盤 ---
check "incus (実行可)"                     '^-rwx.* \./usr/bin/incus$'
check "k3s バイナリ (実行可)"              '^-rwx.* \./usr/local/bin/k3s$'
check "k3s の systemd unit"                '^-.* \./etc/systemd/system/k3s\.service$'

# --- ビルド環境の痕跡が無いこと ---
check_absent "/etc/machine-id が焼き込まれていない"          '\./etc/machine-id$'
check_absent "/var/lib/dbus/machine-id が焼き込まれていない" '\./var/lib/dbus/machine-id$'
# apt lists は正常な足場 (lock, partial/) 以外に何も残っていないこと。
# mirror 名でのパターン照合だと security/Radxa/変更後 mirror の index を見逃す
apt_residue="$(grep -E ' \./var/lib/apt/lists/.' <<< "$listing" \
	| grep -vE ' \./var/lib/apt/lists/(lock|partial/|auxfiles/)$' || true)"
if [[ -n $apt_residue ]]; then
	echo "NG: apt lists に index の残骸がある:"
	echo "$apt_residue" | head -5
	fail=1
else
	echo "ok: apt lists に index の残骸が無い"
fi

if ((fail)); then
	echo "smoke test: FAILED" >&2
	exit 1
fi
echo "smoke test: PASSED"
