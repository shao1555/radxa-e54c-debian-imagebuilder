# SPDX-License-Identifier: GPL-2.0-only
# boot テスト (QEMU ゲスト内) の共通 helper。
# 各テストは `. "$E54C_BOOT_TEST_LIB"` で読み込み、末尾で `exit "$fail"` する。
# 注意: シリアル転送されるため各行は短く保つこと
fail=0
chk() {
	desc="$1"
	cmd="$2"
	if sh -c "$cmd" > /dev/null 2>&1; then
		echo "BOOTCHK ok: $desc"
	else
		echo "BOOTCHK NG: $desc"
		fail=1
	fi
}
