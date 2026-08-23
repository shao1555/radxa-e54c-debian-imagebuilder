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

# devcontainer 内は root で動くため sudo を無効化。非 root では sudo の
# env_reset で DEFAULT_PASSWORD が落ちないよう明示的に保持する
SUDO="sudo --preserve-env=DEFAULT_PASSWORD"
[[ $EUID -eq 0 ]] && SUDO=""

# ローカルビルドの秘匿設定。make 経由の include だと $ や # を含むパスワードが
# make の構文解釈で壊れるため、shell で source する (値はシングルクォート推奨)
if [[ -f "$TOP/.env" ]]; then
	# shellcheck source=/dev/null
	source "$TOP/.env"
fi

# デフォルトユーザー (debian) のパスワード。値は bdebstrap.yaml に埋め込まれず、
# フック実行時にこの環境変数から読まれる (リリース同梱の yaml に漏れない)
if [[ -z "${DEFAULT_PASSWORD:-}" ]]; then
	cat >&2 <<- 'EOF'
	エラー: DEFAULT_PASSWORD が未設定です。
	  ローカルビルド: cp .env.example .env して DEFAULT_PASSWORD を設定してください
	  (CI は workflow が DEFAULT_PASSWORD=debian を設定します)
	EOF
	exit 1
fi
# chpasswd は行区切りで解釈するため、CR/LF を含む値は事故のもとなので拒否する
if [[ "$DEFAULT_PASSWORD" == *$'\n'* || "$DEFAULT_PASSWORD" == *$'\r'* ]]; then
	echo "エラー: DEFAULT_PASSWORD に改行 (CR/LF) を含めることはできません" >&2
	exit 1
fi
export DEFAULT_PASSWORD

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

python3 scripts/render-bdebstrap.py "$OUT"

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
		curl -fL "$url" -o "$deb"
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
echo "rootfs: $OUT/build/rootfs.tar"
echo "manifest: $OUT/build/manifest"
