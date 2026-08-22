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

python3 scripts/render-bdebstrap.py "$OUT"

# Radxa の APT 鍵 (U-Boot deb の取得に必要) をホスト側 keyring から拾えるよう準備
KEYRING_DIR="$OUT/keyrings"
mkdir -p "$KEYRING_DIR"
cp -a /usr/share/keyrings/. "$KEYRING_DIR/" 2>/dev/null || true
if [[ ! -f "$KEYRING_DIR/radxa-archive-keyring.gpg" ]]; then
	# files.list から keyring deb の現行パスを解決して取得する
	# (curl | grep -m1 は SIGPIPE で curl が exit 23 になり pipefail に殺されるため、
	#  一旦変数に受けてから grep する)
	repo="$(python3 -c "import yaml;print(yaml.safe_load(open('config.yaml'))['uboot']['apt_repo'])")"
	files_list="$(curl -fsL "$repo/files.list")"
	path="$(grep -m1 'radxa-archive-keyring_.*_all\.deb' <<< "$files_list" | sed 's|^\./||')"
	curl -fL "$repo/$path" -o /tmp/radxa-keyring.deb
	# radxa-archive-keyring.gpg は年次 keyring への symlink なので、実体ごと全て展開する
	tmpk="$(mktemp -d)"
	dpkg-deb --fsys-tarfile /tmp/radxa-keyring.deb | tar -x -C "$tmpk" ./usr/share/keyrings
	cp -a "$tmpk/usr/share/keyrings/." "$KEYRING_DIR/"
	rm -rf "$tmpk"
	[[ -s "$(readlink -f "$KEYRING_DIR/radxa-archive-keyring.gpg")" ]] || {
		echo "radxa keyring の展開に失敗" >&2; exit 1; }
fi

$SUDO bdebstrap -c "$OUT/bdebstrap.yaml" \
	--name "$OUT/build" \
	--force \
	--keyring "$KEYRING_DIR"

$SUDO chown -R "$(id -u):$(id -g)" "$OUT/build"
echo "rootfs: $OUT/build/rootfs.tar"
echo "manifest: $OUT/build/manifest"
