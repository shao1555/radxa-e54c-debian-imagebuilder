# SPDX-License-Identifier: GPL-2.0-only
# devcontainer 内での実行を想定したエントリポイント
# (VS Code: "Reopen in Container" → ターミナルで `make`)

# ローカルビルドの秘匿設定は .env (git 管理外) に置き、build-rootfs.sh が
# shell として source する。make で include すると $ や # を含むパスワードが
# make の構文解釈で壊れるため、ここでは読み込まない

# 注意: 変数名に VERSION を使ってはいけない。make のコマンドライン変数は
# MAKEFLAGS 経由で子プロセスの make (カーネルビルド) にも伝播し、カーネルの
# Makefile の VERSION (=7) を上書きして LINUX_VERSION_CODE を壊す (実際に踏んだ)
IMG_VERSION ?= dev

.PHONY: all kernel rootfs image resolve test-resolver check clean distclean

all: kernel rootfs image

kernel:
	scripts/build-kernel.sh

rootfs:
	scripts/build-rootfs.sh
	scripts/smoke-test-rootfs.sh

# canonical ModulePlan の再生成 (stale plan エラー時の復旧にも使う)
resolve:
	python3 scripts/resolve-modules.py resolve --output out/meta/module-plan.json

# resolver の fixture テスト (determinism / traversal / tampering の異常系)
test-resolver:
	python3 scripts/tests/test_resolver.py

# resolver テスト + rootfs.tar の回帰検査
check: test-resolver
	scripts/smoke-test-rootfs.sh

image:
	VERSION=$(IMG_VERSION) scripts/build-image.sh

# 生成物のみ削除 (ダウンロード済みカーネルソースは残す)
clean:
	rm -rf out/rootfs out/*.img out/*.img.xz out/debs

distclean:
	rm -rf out
