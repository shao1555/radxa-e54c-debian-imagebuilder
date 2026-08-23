#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# scripts/secrets-lib.sh (materialize_secrets) の軽量テスト。
# rootfs ビルドを伴わず、shell 側の secret 取り扱い規約だけを検証する:
#   1. 2 つの module が同じ secret ID を使っても別ファイルに materialize される
#   2. 2 つの secret が同じ source 環境変数を共有できる
#   3. framework は空・複数行 (CR/LF 含む) の secret を変更せず materialize する
#      (形式検証は consumer の hook の責務)
#   4. 参照元の環境変数は materialize 後に unset される
# 実行: make test-resolver (fixture テストと同時) / CI の rootfs job 冒頭
set -euo pipefail
cd "$(dirname "$0")/../.."

# shellcheck source=scripts/secrets-lib.sh
source scripts/secrets-lib.sh

fail=0
chk() { # chk <説明> <コマンド...>
	local desc="$1"
	shift
	if "$@"; then
		echo "ok: $desc"
	else
		echo "NG: $desc" >&2
		fail=1
	fi
}

# fileEnvironment 名は resolver の符号化規則から導出する (ハードコードすると
# 規則変更時にテストが黙って形骸化するため)
enc() {
	python3 -c '
import sys
sys.path.insert(0, "scripts")
from module_plan import secret_file_environment
print(secret_file_environment(sys.argv[1], sys.argv[2]))' "$1" "$2"
}

DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

# --- 1. 同じ secret ID を持つ 2 module → 別ファイル ---
env_a="$(enc module-a api-token)"
env_b="$(enc module-b api-token)"
export SRC_A="value-a" SRC_B="value-b"
materialize_secrets "$DIR" <<- EOF
	api-token	module-a	SRC_A	$env_a
	api-token	module-b	SRC_B	$env_b
EOF
chk "同一 secret ID でも fileEnvironment 名が別" test "$env_a" != "$env_b"
chk "module-a のファイルが存在する" test -f "$DIR/$env_a"
chk "module-b のファイルが存在する" test -f "$DIR/$env_b"
chk "module-a の値が正しい" test "$(cat "$DIR/$env_a")" = "value-a"
chk "module-b の値が正しい (上書きされていない)" test "$(cat "$DIR/$env_b")" = "value-b"
chk "パーミッションが 0600" test "$(stat -c %a "$DIR/$env_a")" = "600"
chk "fileEnvironment 変数がパスを指す" test "${!env_a}" = "$DIR/$env_a"

# --- 2. 同じ source 環境変数を 2 つの secret が共有できる ---
env_c="$(enc module-c token)"
env_d="$(enc module-d token)"
export SHARED_SRC="shared-value"
materialize_secrets "$DIR" <<- EOF
	token	module-c	SHARED_SRC	$env_c
	token	module-d	SHARED_SRC	$env_d
EOF
chk "共有 source の 1 件目が materialize される" \
	test "$(cat "$DIR/$env_c")" = "shared-value"
chk "共有 source の 2 件目も materialize される (unset は最後に一括)" \
	test "$(cat "$DIR/$env_d")" = "shared-value"

# --- 3. 空・複数行の secret を変更せず materialize する (opaque) ---
env_e="$(enc module-e empty)"
env_f="$(enc module-f multiline)"
export EMPTY_SRC=""
export ML_SRC=$'line1\nline2\r\n'
materialize_secrets "$DIR" <<- EOF
	empty	module-e	EMPTY_SRC	$env_e
	multiline	module-f	ML_SRC	$env_f
EOF
chk "空 secret が空ファイルとして materialize される" test -f "$DIR/$env_e"
chk "空 secret の中身が空のまま" test ! -s "$DIR/$env_e"
printf 'line1\nline2\r\n' > "$DIR/expected-ml"
chk "複数行 (CR/LF・末尾改行含む) secret が byte-exact に materialize される" \
	cmp -s "$DIR/$env_f" "$DIR/expected-ml"

# --- 4. 参照元の環境変数が materialize 後に unset される ---
for v in SRC_A SRC_B SHARED_SRC EMPTY_SRC ML_SRC; do
	if [[ -v $v ]]; then
		echo "NG: $v が unset されていない" >&2
		fail=1
	else
		echo "ok: $v が unset されている"
	fi
done

# --- 参照元が未設定なら明示的に失敗する ---
env_g="$(enc module-g missing)"
if (materialize_secrets "$DIR" <<< "$(printf 'missing\tmodule-g\tNO_SUCH_SRC\t%s' "$env_g")") 2> /dev/null; then
	echo "NG: 未設定 source でも成功してしまった" >&2
	fail=1
else
	echo "ok: 未設定 source は明示的に失敗する"
fi

# --- 参照は実プロセス環境のみ (shell 内部変数は source にならない) ---
env_i="$(enc module-i internal)"
SHELL_ONLY_VAR="not-exported"
if (materialize_secrets "$DIR" <<< "$(printf 'internal\tmodule-i\tSHELL_ONLY_VAR\t%s' "$env_i")") 2> /dev/null; then
	echo "NG: export されていない shell 変数を source として読んでしまった" >&2
	fail=1
else
	echo "ok: export されていない shell 変数は「未設定」として失敗する"
fi
unset SHELL_ONLY_VAR

# --- readonly 変数 (EUID 等) は source にできない ---
env_j="$(enc module-j ro)"
if (materialize_secrets "$DIR" <<< "$(printf 'ro\tmodule-j\tEUID\t%s' "$env_j")") 2> /dev/null; then
	echo "NG: readonly 変数 (EUID) でも成功してしまった" >&2
	fail=1
else
	echo "ok: readonly 変数 (EUID) は明示的に失敗する"
fi

# --- source 名が予約名前空間 (E54C_SECRET_FILE_*) と交差したら失敗する ---
env_h="$(enc module-h token)"
export E54C_SECRET_FILE_FOO="value"
if (materialize_secrets "$DIR" <<< "$(printf 'token\tmodule-h\tE54C_SECRET_FILE_FOO\t%s' "$env_h")") 2> /dev/null; then
	echo "NG: 予約名前空間の source 名でも成功してしまった" >&2
	fail=1
else
	echo "ok: 予約名前空間の source 名は明示的に失敗する"
fi
unset E54C_SECRET_FILE_FOO

if [[ $fail -eq 0 ]]; then
	echo "secret materialize tests: PASSED"
fi
exit "$fail"
