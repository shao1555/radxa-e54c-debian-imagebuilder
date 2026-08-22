#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# mainline カーネルを取得 → patch/dts/config を適用 → arm64 の deb を生成する。
# 実行環境: Linux (CI)。必要: crossbuild-essential-arm64, flex, bison, bc,
#           libssl-dev, libelf-dev, python3, rsync, kmod, debhelper, git, curl, xz-utils
set -euo pipefail

cd "$(dirname "$0")/.."
TOP="$PWD"
OUT="$TOP/out"
# ソース展開・ビルドは高速なローカル FS で行う (macOS Docker の virtiofs 上では
# tar のディレクトリ展開が失敗し、ビルドも著しく遅いため。devcontainer では
# E54C_BUILD_DIR=/build が Docker ボリュームとしてマウントされる)
BUILD_BASE="${E54C_BUILD_DIR:-$OUT}"
mkdir -p "$OUT/debs" "$BUILD_BASE/src"

ver="$(python3 -c "import yaml;print(yaml.safe_load(open('config.yaml'))['kernel']['version'])")"
localver="$(python3 -c "import yaml;print(yaml.safe_load(open('config.yaml'))['kernel']['localversion'])")"

# --- ソース取得 (rc は git、リリース版は cdn の tarball) ---
if [[ "$ver" == *-rc* ]]; then
	src="$BUILD_BASE/src/linux-$ver"
	[[ -d $src ]] || git clone --depth 1 --branch "v$ver" \
		https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "$src"
else
	major="${ver%%.*}"
	tar="$BUILD_BASE/src/linux-$ver.tar.xz"
	[[ -f $tar ]] || curl -fL "https://cdn.kernel.org/pub/linux/kernel/v${major}.x/linux-$ver.tar.xz" -o "$tar"
	src="$BUILD_BASE/src/linux-$ver"
	[[ -d $src ]] || tar -C "$BUILD_BASE/src" -xf "$tar"
fi
cd "$src"

# --- パッチ適用 (ファイル名昇順) ---
shopt -s nullglob
for p in "$TOP"/kernel/patches/[0-9]*.patch; do
	echo "Applying $(basename "$p")"
	git apply --check "$p" 2>/dev/null && git apply "$p" || patch -p1 --forward < "$p"
done

# --- DTS の投入 (in-tree に同名が存在しない場合のみ。上流化されたら自動で無効) ---
for d in "$TOP"/kernel/dts/*.dts; do
	base="$(basename "$d")"
	dst="arch/arm64/boot/dts/rockchip/$base"
	if [[ -e $dst ]]; then
		echo "skip $base (already in-tree)"
	else
		cp "$d" "$dst"
		dtb="${base%.dts}.dtb"
		grep -q "$dtb" arch/arm64/boot/dts/rockchip/Makefile || \
			echo "dtb-\$(CONFIG_ARCH_ROCKCHIP) += $dtb" >> arch/arm64/boot/dts/rockchip/Makefile
		echo "added $base"
	fi
done

# --- config: defconfig + fragments ---
# コンテナ/ホストが arm64 ならネイティブビルド、それ以外はクロスビルド
export ARCH=arm64
if [[ "$(uname -m)" != "aarch64" ]]; then
	export CROSS_COMPILE=aarch64-linux-gnu-
fi
make defconfig
frags=()
while IFS= read -r f; do frags+=("$TOP/$f"); done < <(python3 -c "
import yaml
for f in yaml.safe_load(open('$TOP/config.yaml'))['kernel'].get('fragments', []): print(f)")
scripts/kconfig/merge_config.sh -m .config "${frags[@]}"
make olddefconfig

# --- ビルド (deb 生成) ---
# ccache があれば使う (CI ではキャッシュ復元と組み合わせて再コンパイルを短縮)
MAKE_CC=()
if command -v ccache > /dev/null; then
	export CCACHE_DIR="${CCACHE_DIR:-${E54C_BUILD_DIR:-$OUT}/ccache}"
	export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-2G}"
	mkdir -p "$CCACHE_DIR"
	MAKE_CC=(CC="ccache ${CROSS_COMPILE:-}gcc")
	ccache -z > /dev/null || true
fi
make -j"$(nproc)" LOCALVERSION="$localver" KDEB_PKGVERSION="${ver//-/\~}${localver}-1" \
	"${MAKE_CC[@]}" bindeb-pkg
command -v ccache > /dev/null && ccache -s | head -5 || true
mv ../linux-*.deb "$OUT/debs/"
ls -la "$OUT/debs/"
