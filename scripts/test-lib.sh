# SPDX-License-Identifier: GPL-2.0-only
# rootfs テスト (core smoke test / module rootfs test) の共通 helper。
# 利用側は以下の環境変数が設定された状態で `source "$E54C_TEST_LIB"` する:
#   E54C_ROOTFS_TAR     rootfs.tar のパス (内容の抽出検査に使う)
#   E54C_ROOTFS_LISTING tar -tvf の出力を保存した一時ファイル
#                       (モジュールごとに巨大な listing を再生成しないため)
# 検査は $fail に 1 を立てる。テストスクリプトは末尾で `exit "$fail"` すること。

fail=0

check() { # <説明> <grep -E パターン (listing に対する)>
	if grep -qE "$2" "$E54C_ROOTFS_LISTING"; then
		echo "ok: $1"
	else
		echo "NG: $1 (pattern: $2)"
		fail=1
	fi
}

check_absent() { # <説明> <grep -E パターン>
	if grep -qE "$2" "$E54C_ROOTFS_LISTING"; then
		echo "NG: $1 (存在してはいけない)"
		fail=1
	else
		echo "ok: $1"
	fi
}

# systemd unit の enable 判定。フルパス + symlink 種別 + リンク先まで厳密に照合する。
# パス末尾だけの照合だと var/lib/systemd/deb-systemd-helper-enabled/ 配下の
# metadata に誤一致し、本命の /etc/systemd/system/ の symlink 欠落を見逃す
enabled() { # <説明> <wants 配下の相対パス> <リンク先ユニット>
	check "$1" "^l.* \\./etc/systemd/system/$2 -> /usr/lib/systemd/system/$3\$"
}

# tar 内の 1 ファイルの中身を標準出力へ (存在しなければ空)
tar_cat() { # <tar 内パス (./ 始まり)>
	tar -xOf "$E54C_ROOTFS_TAR" "$1" 2> /dev/null
}
