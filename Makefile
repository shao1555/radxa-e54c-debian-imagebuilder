# SPDX-License-Identifier: GPL-2.0-only
# devcontainer 内での実行を想定したエントリポイント
# (VS Code: "Reopen in Container" → ターミナルで `make`)

# 注意: 変数名に VERSION を使ってはいけない。make のコマンドライン変数は
# MAKEFLAGS 経由で子プロセスの make (カーネルビルド) にも伝播し、カーネルの
# Makefile の VERSION (=7) を上書きして LINUX_VERSION_CODE を壊す (実際に踏んだ)
IMG_VERSION ?= dev

.PHONY: all kernel rootfs image clean distclean

all: kernel rootfs image

kernel:
	scripts/build-kernel.sh

rootfs:
	scripts/build-rootfs.sh

image:
	VERSION=$(IMG_VERSION) scripts/build-image.sh

# 生成物のみ削除 (ダウンロード済みカーネルソースは残す)
clean:
	rm -rf out/rootfs out/*.img out/*.img.xz out/debs

distclean:
	rm -rf out
