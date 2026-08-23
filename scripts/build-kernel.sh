#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# mainline カーネルを取得 → patch/dts/config を適用 → arm64 の deb を生成する。
# 実行環境: Linux (CI)。必要: crossbuild-essential-arm64, flex, bison, bc,
#           libssl-dev, libelf-dev, python3, rsync, kmod, debhelper, git, curl, xz-utils
set -euo pipefail

cd "$(dirname "$0")/.."
TOP="$PWD"
OUT="$TOP/out"

# 親 make から MAKEFLAGS 経由でコマンドライン変数 (例: IMG_VERSION、かつて VERSION) が
# カーネルの make に漏れて Makefile 変数を上書きしないよう、環境を消毒する
unset MAKEFLAGS MAKELEVEL MAKEOVERRIDES MFLAGS 2>/dev/null || true
# ソース展開・ビルドは高速なローカル FS で行う (macOS Docker の virtiofs 上では
# tar のディレクトリ展開が失敗し、ビルドも著しく遅いため。devcontainer では
# E54C_BUILD_DIR=/build が Docker ボリュームとしてマウントされる)
BUILD_BASE="${E54C_BUILD_DIR:-$OUT}"
mkdir -p "$OUT/debs" "$BUILD_BASE/src"

ver="$(python3 -c "import yaml;print(yaml.safe_load(open('config.yaml'))['kernel']['version'])")"
localver="$(python3 -c "import yaml;print(yaml.safe_load(open('config.yaml'))['kernel']['localversion'])")"

# --- ソース取得 (rc は git、リリース版は cdn の tarball) ---
# 毎回 pristine な状態から始める (前回の DTS コピーやパッチが残ったツリーへの
# 再適用は状態管理が不安定になる。速度は ccache が担保する)
if [[ "$ver" == *-rc* ]]; then
	src="$BUILD_BASE/src/linux-$ver"
	if [[ -d $src/.git ]]; then
		git -C "$src" reset --hard "v$ver"
		git -C "$src" clean -fdx
	else
		rm -rf "$src"
		git clone --depth 1 --branch "v$ver" \
			https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "$src"
	fi
else
	# release 版は dependencies.lock.yaml の URL から取得し sha256 を検証する
	# (キャッシュ済み tarball も毎回検証する。-rc 版の git clone は対象外)
	lock_ver="$(python3 scripts/lock-get.py kernel.version)"
	lock_url="$(python3 scripts/lock-get.py kernel.url)"
	lock_sha="$(python3 scripts/lock-get.py kernel.sha256)"
	if [[ "$lock_ver" != "$ver" ]]; then
		echo "エラー: config.yaml (kernel.version=$ver) と dependencies.lock.yaml" >&2
		echo "  (kernel.version=$lock_ver) が食い違っている。lock を更新すること" >&2
		exit 1
	fi
	tar="$BUILD_BASE/src/linux-$ver.tar.xz"
	[[ -f $tar ]] || curl -fL "$lock_url" -o "$tar"
	sha256sum -c --status <<< "$lock_sha  $tar" || {
		echo "エラー: linux-$ver.tar.xz の sha256 が lock と一致しない" >&2
		rm -f "$tar"
		exit 1
	}
	src="$BUILD_BASE/src/linux-$ver"
	rm -rf "$src"
	tar -C "$BUILD_BASE/src" -xf "$tar"
fi
cd "$src"

# --- パッチ適用 (ファイル名昇順) ---
shopt -s nullglob
for p in "$TOP"/kernel/patches/[0-9]*.patch; do
	echo "Applying $(basename "$p")"
	git apply --check "$p" 2>/dev/null && git apply "$p" || patch -p1 --forward < "$p"
done

# --- DTS の投入 ---
# ソースは毎回 pristine なので、「同名が存在する」= 本当に上流に収録済み。
# 上流化されたら自動でこちらのコピーが不使用になる (7.3 で E54C が入る見込み)
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

# --- config: ベース (config.yaml の kernel.base_config) + fragments ---
# コンテナ/ホストが arm64 ならネイティブビルド、それ以外はクロスビルド
export ARCH=arm64
if [[ "$(uname -m)" != "aarch64" ]]; then
	export CROSS_COMPILE=aarch64-linux-gnu-
fi

base_config="$(python3 -c "
import yaml
print(yaml.safe_load(open('$TOP/config.yaml'))['kernel'].get('base_config', 'defconfig'))")"
case "$base_config" in
defconfig)
	make defconfig
	;;
debian)
	# Debian の arm64 config を seed にする (網羅的だがビルド時間は数倍になる)。
	# devcontainer の linux-config パッケージから取得
	dcfg="$( (ls /usr/src/linux-config-*/config.arm64_none_arm64.xz 2> /dev/null | head -1) || true)"
	if [[ -z $dcfg ]]; then
		echo "エラー: linux-config パッケージが無い (arm64 コンテナの devcontainer で実行すること)" >&2
		exit 1
	fi
	xz -dc "$dcfg" > .config
	;;
*)
	echo "エラー: kernel.base_config の値が不正: $base_config (defconfig|debian)" >&2
	exit 1
	;;
esac

frags=()
while IFS= read -r f; do frags+=("$TOP/$f"); done < <(python3 -c "
import yaml
for f in yaml.safe_load(open('$TOP/config.yaml'))['kernel'].get('fragments', []): print(f)")
scripts/kconfig/merge_config.sh -m .config "${frags[@]}"
make olddefconfig

# --- fragment 検証: 要求した値が依存関係不足等で黙って落ちていないか ---
# (=m 要求は =y でも可、=y と文字列値は厳密一致、"is not set" は不在を要求)
cfg_fail=0
for f in "${frags[@]}"; do
	while IFS= read -r line; do
		if [[ $line =~ ^(CONFIG_[A-Za-z0-9_]+)=(.+)$ ]]; then
			opt="${BASH_REMATCH[1]}" want="${BASH_REMATCH[2]}"
			# grep 不一致 (unset) でも set -e で落ちず全行の照合を続ける
			got="$( (grep -E "^${opt}=" .config | head -1 | cut -d= -f2-) || true)"
			case "$want" in
			m) [[ $got == m || $got == y ]] || { echo "NG: $opt (要求 m, 実際 ${got:-unset})"; cfg_fail=1; } ;;
			y) [[ $got == y ]] || { echo "NG: $opt (要求 y, 実際 ${got:-unset})"; cfg_fail=1; } ;;
			*) [[ $got == "$want" ]] || { echo "NG: $opt (要求 $want, 実際 ${got:-unset})"; cfg_fail=1; } ;;
			esac
		elif [[ $line =~ ^#\ (CONFIG_[A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
			opt="${BASH_REMATCH[1]}"
			if grep -qE "^${opt}=" .config; then
				echo "NG: $opt (要求 not set, 実際 $(grep -E "^${opt}=" .config | head -1))"
				cfg_fail=1
			fi
		fi
	done < "$f"
done
if ((cfg_fail)); then
	echo "エラー: config fragment の要求が最終 .config に反映されていない (依存関係を確認)" >&2
	exit 1
fi
echo "config fragment verification passed."

# --- ビルド (deb 生成) ---
# 中断・失敗した前回ビルドの deb が親ディレクトリに残っていると mv で一緒に
# 回収されてしまうため、ビルド前に staging を掃除する
rm -f "$BUILD_BASE/src"/linux-*.deb "$BUILD_BASE/src"/linux-*.changes "$BUILD_BASE/src"/linux-*.buildinfo
# ccache があれば使う (CI ではキャッシュ復元と組み合わせて再コンパイルを短縮)
MAKE_CC=()
if command -v ccache > /dev/null; then
	export CCACHE_DIR="${CCACHE_DIR:-${E54C_BUILD_DIR:-$OUT}/ccache}"
	export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-2G}"
	mkdir -p "$CCACHE_DIR"
	MAKE_CC=(CC="ccache ${CROSS_COMPILE:-}gcc")
	ccache -z > /dev/null || true
fi
# KBUILD_IMAGE: arm64 の既定は Image.gz だが、U-Boot での gzip 展開は
# kernel_comp_addr_r 等の env 設定が必要で、実機の vendor U-Boot 2017.09 は
# そもそも booti の gzip 展開に未対応 (QEMU ブートテストで検出)。
# Debian/Radxa と同様に非圧縮 Image を vmlinuz として収録する
make -j"$(nproc)" LOCALVERSION="$localver" KDEB_PKGVERSION="${ver//-/\~}${localver}-1" \
	KBUILD_IMAGE=arch/arm64/boot/Image \
	"${MAKE_CC[@]}" bindeb-pkg
command -v ccache > /dev/null && ccache -s | head -5 || true
# 今回のビルドが期待どおりの成果物を出したことを確認してから out/debs を置換する
# (期待名が無いのに古い out/debs を消してしまう事故を防ぐ)
if ! compgen -G "../linux-image-*${localver}_*.deb" > /dev/null; then
	echo "エラー: 期待する linux-image${localver} の deb が生成されていない" >&2
	exit 1
fi
rm -f "$OUT/debs"/linux-*.deb
mv ../linux-*.deb "$OUT/debs/"
ls -la "$OUT/debs/"
