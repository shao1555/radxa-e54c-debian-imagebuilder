# SPDX-License-Identifier: GPL-2.0-only
# secret input の materialize 処理 (build-rootfs.sh が source する)。
# 単体でテストできるよう関数として切り出している
# (scripts/tests/test-secret-materialize.sh)。

# materialize_secrets <dir>
#   stdin: required-secrets の TSV (id, consumer, source-env-name, fileEnvironment)
#
# framework は secret を opaque なバイト列として扱い、「参照元が未設定」以外の
# 検証はしない (形式検証は用途を知る consumer の hook が行う)。二段階処理:
#   (1) 全 secret を <dir>/<fileEnvironment> (module namespace 込みで一意な
#       ファイル名) に 0600 で materialize し、fileEnvironment 変数に
#       そのパスを export する
#   (2) 全 materialize 後に参照元の環境変数を一括 unset する
#       (materialize 後に起動する子プロセスへ raw 値を継承しない)
# 呼び出し後、$secret_env_vars に export した fileEnvironment 変数名の
# カンマ区切りが入る (sudo --preserve-env 用)。
materialize_secrets() {
	local dir="$1" sid consumer src_name file_env src_names=""
	secret_env_vars=""
	while IFS=$'\t' read -r sid consumer src_name file_env; do
		[[ -n $sid ]] || continue
		if [[ ! -v $src_name ]]; then
			{
				echo "エラー: $src_name が未設定です (module '$consumer' の secret '$sid')。"
				echo "  ローカルビルド: cp .env.example .env して $src_name を設定してください"
				echo "  (CI は workflow が設定します)"
			} >&2
			return 1
		fi
		(umask 077 && printf '%s' "${!src_name}" > "$dir/$file_env")
		export "${file_env}=$dir/$file_env"
		secret_env_vars="${secret_env_vars:+$secret_env_vars,}${file_env}"
		src_names="$src_names $src_name"
	done
	local n
	for n in $src_names; do unset "$n"; done
}
