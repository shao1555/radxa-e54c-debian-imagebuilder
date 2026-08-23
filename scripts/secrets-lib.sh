# SPDX-License-Identifier: GPL-2.0-only
# secret input の materialize 処理 (build-rootfs.sh / boot-test.sh が source する)。
# 単体でテストできるよう関数として切り出している
# (scripts/tests/test-secret-materialize.sh)。

# secret_env_value <name>
#   外部から builder プロセスに与えられた環境変数 <name> の値を byte-exact に
#   $secret_value へ格納する。参照は printenv (= 実プロセス環境のみ) で行い、
#   スクリプトの shell 内部変数は対象外。source 名前空間が framework の内部
#   状態と交差しない (.env はエクスポートして source すること: set -a)。
#   戻り値: 0=取得, 1=未設定, 2=不正な source 名 (メッセージ出力済み)
secret_env_value() {
	local name="$1" raw
	# E54C_SECRET_FILE_* は fileEnvironment の予約名前空間。source 名が
	# ここと交差すると export / unset が secret 値とパスを混線させるため
	# 拒否する (resolver も resolve 時と load 時に同じ規則で拒否する)
	if [[ $name == E54C_SECRET_FILE_* ]]; then
		echo "エラー: source 環境変数名 $name は予約名前空間 (E54C_SECRET_FILE_*) と衝突する" >&2
		return 2
	fi
	# bash の readonly / 特殊変数 (EUID 等) は unset できず、materialize 後の
	# 一括 unset が失敗するため source として拒否する
	if ! (unset "$name" 2> /dev/null); then
		echo "エラー: source 環境変数名 $name は shell の readonly 変数と衝突する" >&2
		return 2
	fi
	printenv -- "$name" > /dev/null || return 1
	# printenv は値の後に改行を 1 つ出力する。command substitution の末尾改行
	# 除去で値自身の末尾改行まで失わないよう、sentinel を付けて 1 つだけ剥がす
	raw="$(printenv -- "$name"; printf x)"
	raw="${raw%x}"
	secret_value="${raw%$'\n'}"
}

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
	local dir="$1" sid consumer src_name file_env src_names="" rc
	secret_env_vars=""
	while IFS=$'\t' read -r sid consumer src_name file_env; do
		[[ -n $sid ]] || continue
		rc=0
		secret_env_value "$src_name" || rc=$?
		if [[ $rc -eq 1 ]]; then
			{
				echo "エラー: $src_name が未設定です (module '$consumer' の secret '$sid')。"
				echo "  ローカルビルド: cp .env.example .env して $src_name を設定してください"
				echo "  (CI は workflow が設定します)"
			} >&2
			return 1
		elif [[ $rc -ne 0 ]]; then
			return 1
		fi
		(umask 077 && printf '%s' "$secret_value" > "$dir/$file_env")
		export "${file_env}=$dir/$file_env"
		secret_env_vars="${secret_env_vars:+$secret_env_vars,}${file_env}"
		src_names="$src_names $src_name"
	done
	local n
	for n in $src_names; do unset "$n"; done
	unset secret_value
}
