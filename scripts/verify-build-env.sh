#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ビルド環境 (devcontainer) の snapshot 固定が dependencies.lock.yaml と
# 一致していることを確認する。Dockerfile の snapshot はハードコードのため、
# lock だけ更新してイメージを作り直し忘れると成果物の依存が食い違う。
# それをビルド時に fail-fast で検出する (build-kernel.sh / build-rootfs.sh が呼ぶ)
set -euo pipefail
cd "$(dirname "$0")/.."

MARKER="/etc/e54c-snapshot"
if [[ ! -f $MARKER ]]; then
	echo "エラー: $MARKER が無い。snapshot 固定済みの devcontainer 内で実行すること" >&2
	echo "  (.devcontainer/Dockerfile からイメージを作り直すと入る)" >&2
	exit 1
fi
want="$(python3 scripts/lock-get.py debian.snapshot) $(python3 scripts/lock-get.py debian.security_snapshot)"
got="$(cat "$MARKER")"
if [[ "$got" != "$want" ]]; then
	echo "エラー: devcontainer の snapshot ($got) が lock ($want) と一致しない。" >&2
	echo "  dependencies.lock.yaml と .devcontainer/Dockerfile を揃えて、" >&2
	echo "  devcontainer イメージを作り直すこと" >&2
	exit 1
fi
# ベースイメージの digest も lock と一致していること (Renovate が Dockerfile
# 側だけ更新した場合にここで検出する。lock 側の追随は refresh-lock.py が行う)
BASE_MARKER="/etc/e54c-base-image"
if [[ -f $BASE_MARKER ]]; then
	want_base="$(python3 scripts/lock-get.py devcontainer.base_image)"
	got_base="$(cat "$BASE_MARKER")"
	if [[ "$got_base" != "$want_base" ]]; then
		echo "エラー: devcontainer のベースイメージ ($got_base) が" >&2
		echo "  lock ($want_base) と一致しない。scripts/refresh-lock.py で揃えること" >&2
		exit 1
	fi
fi
echo "build env verified: snapshot $got"
