# SPDX-License-Identifier: GPL-2.0-only
# devcontainer 内での実行を想定したエントリポイント
# (VS Code: "Reopen in Container" → ターミナルで `make`)

VERSION ?= dev

.PHONY: all ci kernel rootfs image clean distclean

all: kernel rootfs image

# CI 用: カーネル deb がキャッシュ復元済みならカーネルビルドをスキップする
ci:
	@if ls out/debs/linux-image-*.deb > /dev/null 2>&1; then \
		echo "==> kernel debs restored from cache, skipping kernel build"; \
	else \
		$(MAKE) kernel; \
	fi
	$(MAKE) rootfs
	$(MAKE) image VERSION=$(VERSION)

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
