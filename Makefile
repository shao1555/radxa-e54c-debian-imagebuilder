# SPDX-License-Identifier: GPL-2.0-only
# devcontainer 内での実行を想定したエントリポイント
# (VS Code: "Reopen in Container" → ターミナルで `make`)

VERSION ?= dev

.PHONY: all kernel rootfs image clean distclean

all: kernel rootfs image

kernel:
	scripts/build-kernel.sh

rootfs:
	scripts/build-rootfs.sh

image:
	VERSION=$(VERSION) scripts/build-image.sh

# 生成物のみ削除 (ダウンロード済みカーネルソースは残す)
clean:
	rm -rf out/rootfs out/*.img out/*.img.xz out/debs

distclean:
	rm -rf out
