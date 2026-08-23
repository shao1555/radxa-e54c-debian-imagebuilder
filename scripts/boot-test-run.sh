#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# boot テスト bundle の dispatcher (QEMU ゲスト内で root として実行される)。
# core / 各モジュールのテストを独立した subprocess で実行して結果を集約する
# (同一シェルスコープへの連結だと変数・関数・exit・trap が衝突するため)。
# bundle 構成: test-lib.sh / core.sh / modules/<id>/*.sh / run.sh (これ)
dir="$(cd "$(dirname "$0")" && pwd)"
export E54C_BOOT_TEST_LIB="$dir/test-lib.sh"
total=0

run_one() { # <ラベル> <スクリプト> <モジュール ID (core は空)>
	out="$dir/.out.$$"
	E54C_MODULE_ID="$3" "$2" > "$out" 2>&1
	rc=$?
	sed "s/^/$1 /" "$out"
	rm -f "$out"
	if [ "$rc" -ne 0 ]; then
		echo "$1 test failed: $2 (exit $rc)"
		total=1
	fi
}

run_one "core" "$dir/core.sh" ""
for d in "$dir"/modules/*/; do
	[ -d "$d" ] || continue
	mid="$(basename "$d")"
	for t in "$d"*.sh; do
		[ -e "$t" ] || continue
		run_one "module[$mid]" "$t" "$mid"
	done
done

echo "BOOTTEST_RESULT=$total"
