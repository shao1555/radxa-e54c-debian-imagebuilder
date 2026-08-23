#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# bdebstrap で rootfs.tar を生成する。
# 実行環境: Linux (CI)。必要: bdebstrap, mmdebstrap, qemu-user-static (binfmt), python3-yaml
# 事前に scripts/build-kernel.sh を実行して out/debs/ にカーネル deb があること。
set -euo pipefail

cd "$(dirname "$0")/.."
TOP="$PWD"
OUT="$TOP/out/rootfs"
mkdir -p "$OUT"

# devcontainer 内は root で動くため sudo を無効化
SUDO="sudo"
[[ $EUID -eq 0 ]] && SUDO=""

# ローカルビルドの秘匿設定。make 経由の include だと $ や # を含むパスワードが
# make の構文解釈で壊れるため、shell で source する (値はシングルクォート推奨)
if [[ -f "$TOP/.env" ]]; then
	# shellcheck source=/dev/null
	source "$TOP/.env"
fi

# (secret の必要性は plan の requiredSecrets が決める: module manifest の宣言と
#  config.yaml の secretReferences から導出される。module を外せば要求されない)

# カーネル deb と E54C の DTB の存在を事前検証する。無いまま進めると
# 「正常に生成されたが起動不能な rootfs」ができてしまう。
# 投入フックは linux-image-*.deb を全部コピーするため、検証対象と投入対象が
# 一致するよう「非 dbg の image deb は正確に 1 個」を要求する
mapfile -t img_debs < <(ls "$TOP"/out/debs/linux-image-*.deb 2> /dev/null | grep -v -- -dbg || true)
if (( ${#img_debs[@]} != 1 )); then
	echo "エラー: 非 dbg の linux-image deb は正確に 1 個であるべき (現在 ${#img_debs[@]} 個)。" >&2
	echo "  'make kernel' を実行するか、out/debs/ の古い deb を掃除すること" >&2
	exit 1
fi
img_deb="${img_debs[0]}"
mapfile -t hdr_debs < <(ls "$TOP"/out/debs/linux-headers-*.deb 2> /dev/null || true)
if (( ${#hdr_debs[@]} != 1 )); then
	echo "エラー: linux-headers deb は正確に 1 個であるべき (現在 ${#hdr_debs[@]} 個)" >&2
	exit 1
fi
# grep -q をパイプに直結すると SIGPIPE で dpkg-deb が失敗扱いになる
# (pipefail の罠) ため、listing を変数に受けてから照合する。
# DTB は起動時に参照される正規の配置場所までパスで固定して確認する
deb_listing="$(dpkg-deb --fsys-tarfile "$img_deb" | tar -t)"
if ! grep -qE '^\./usr/lib/linux-image-[^/]+/rockchip/rk3582-radxa-e54c\.dtb$' <<< "$deb_listing"; then
	echo "エラー: $img_deb に E54C の DTB (usr/lib/linux-image-*/rockchip/) が同梱されていない" >&2
	exit 1
fi
echo "kernel deb preflight passed: $(basename "$img_deb")"

# ビルド環境の snapshot 固定が lock と一致しているか (fail-fast)
scripts/verify-build-env.sh

# canonical ModulePlan は make resolve (または CI の resolve ステップ) が
# pipeline ごとに一度だけ生成する。ここでは再生成しない。
# 入力の再検証は各 consumer が自プロセス内で行う (render-bdebstrap.py が
# load_plan + verify を実行し、required-secrets 等の CLI も load 時に検証する)
PLAN="$TOP/out/meta/module-plan.json"
if [[ "${1:-}" == "--plan" ]]; then
	PLAN="$2"
	shift 2
fi
[[ -f $PLAN ]] || { echo "エラー: module-plan が無い: $PLAN (make resolve)" >&2; exit 1; }

# secret input の汎用処理 (plan の requiredSecrets を処理する。module ID の
# 特別扱いはしない)。値は環境に一切残さず、0600 の一時ファイルに置いて
# fileEnvironment (パス変数) だけを consumer hook から読める形で export する
SECRETS_DIR="$(mktemp -d)"
trap 'rm -rf "$SECRETS_DIR"' EXIT
secret_env_vars=""
required_secrets="$(python3 scripts/resolve-modules.py required-secrets --plan "$PLAN")"
while IFS=$'\t' read -r sid consumer src_name file_env; do
	[[ -n $sid ]] || continue
	value="${!src_name:-}"
	if [[ -z $value ]]; then
		cat >&2 <<- EOF
		エラー: $src_name が未設定です (module '$consumer' の secret '$sid')。
		  ローカルビルド: cp .env.example .env して $src_name を設定してください
		  (CI は workflow が設定します)
		EOF
		exit 1
	fi
	# chpasswd 等は行区切りで解釈するため、CR/LF を含む値は事故のもとなので拒否する
	if [[ $value == *$'\n'* || $value == *$'\r'* ]]; then
		echo "エラー: $src_name に改行 (CR/LF) を含めることはできません" >&2
		exit 1
	fi
	(umask 077 && printf '%s' "$value" > "$SECRETS_DIR/$sid")
	export "${file_env}=$SECRETS_DIR/$sid"
	secret_env_vars="${secret_env_vars:+$secret_env_vars,}${file_env}"
	# 値そのものは必ず環境から外す (bdebstrap 配下の全 hook が継承するのを防ぐ)
	unset "$src_name"
done <<< "$required_secrets"
# sudo 経由の場合、secret ファイルのパス変数だけを通す (値そのものは通らない)
if [[ -n $secret_env_vars && $EUID -ne 0 ]]; then
	SUDO="sudo --preserve-env=${secret_env_vars}"
fi

python3 scripts/render-bdebstrap.py --plan "$PLAN" "$OUT"

# Radxa の deb (keyring / U-Boot) は apt 解決せず、dependencies.lock.yaml で
# 固定した URL から取得して sha256 検証する (customize hook が dpkg で投入する)。
# mmdebstrap は radxa リポジトリに一切触れないため、keyring の事前準備も不要。
# process substitution だと lock-get の失敗 (フィールド欠落等) が while に
# 伝播しないため、先に変数へ受けて set -e で止まるようにする
radxa_lock="$(python3 scripts/lock-get.py radxa.debs)"
RADXA_DEBS="$OUT/radxa-debs"
mkdir -p "$RADXA_DEBS"
expected_debs=()
while IFS=$'\t' read -r pkg ver url sha; do
	deb="$RADXA_DEBS/$(basename "$url")"
	expected_debs+=("$(basename "$url")")
	if [[ ! -f $deb ]] || ! sha256sum -c --status <<< "$sha  $deb" 2> /dev/null; then
		echo "downloading $pkg $ver ..."
		curl -fL --retry 5 --retry-all-errors --retry-delay 10 "$url" -o "$deb"
	fi
	sha256sum -c --status <<< "$sha  $deb" || {
		echo "エラー: $pkg の sha256 が lock と一致しない (upstream の改変または消失)" >&2
		echo "  url: $url" >&2
		rm -f "$deb"
		exit 1
	}
	# deb のメタデータが lock の記載と一致することも確認する
	# (URL の貼り間違いで「検証は通るが別物」になる事故を防ぐ)
	deb_pkg="$(dpkg-deb -f "$deb" Package)"
	deb_ver="$(dpkg-deb -f "$deb" Version)"
	if [[ "$deb_pkg" != "$pkg" || "$deb_ver" != "$ver" ]]; then
		echo "エラー: $deb の中身 ($deb_pkg $deb_ver) が lock の記載 ($pkg $ver) と違う" >&2
		exit 1
	fi
done <<< "$radxa_lock"
# lock に無いファイル (旧版など) が staging に残っていると customize hook の
# dpkg -i *.deb に混入するため、掃除する
for f in "$RADXA_DEBS"/*.deb; do
	[[ -e $f ]] || continue
	name="$(basename "$f")"
	if [[ ! " ${expected_debs[*]} " == *" $name "* ]]; then
		echo "removing stale $name (lock に無い)"
		rm -f "$f"
	fi
done
echo "radxa debs verified: ${expected_debs[*]}"

$SUDO bdebstrap -c "$OUT/bdebstrap.yaml" \
	--name "$OUT/build" \
	--force

$SUDO chown -R "$(id -u):$(id -g)" "$OUT/build"

# rootfs artifact との整合性検証用 sidecar (module 入力の由来 + tar 実体の記録) と、
# plan から導出する人間向け provenance (再解決ではなく純粋な format 変換)
python3 scripts/resolve-modules.py write-sidecar --plan "$PLAN" \
	--rootfs "$OUT/build/rootfs.tar" --output "$OUT/build/rootfs.meta.json"
python3 scripts/resolve-modules.py export-resolved --plan "$PLAN" \
	--output "$TOP/out/meta/resolved-modules.yaml"

echo "rootfs: $OUT/build/rootfs.tar"
echo "manifest: $OUT/build/manifest"
