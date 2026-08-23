#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# 既定ユーザー (debian) の作成。$1 = rootfs のパス。
# パスワードは成果物 (bdebstrap.yaml 等) に値を埋め込まず、実行時の
# 環境変数 $DEFAULT_PASSWORD を参照する (このモジュールへの明示的な secret
# input。未設定・CR/LF 混入は build-rootfs.sh が事前に拒否する)
set -euo pipefail
ROOT="$1"

if [[ -z "${DEFAULT_PASSWORD:-}" ]]; then
	echo "エラー: DEFAULT_PASSWORD が未設定 (default-user モジュールの必須 secret)" >&2
	exit 1
fi

chroot "$ROOT" useradd -m -s /bin/bash -G sudo debian
# dash の echo は \n 等を解釈してしまうため、固定書式の printf を使う
printf '%s:%s\n' debian "$DEFAULT_PASSWORD" | chroot "$ROOT" chpasswd
# 初期パスワードは周知の値 (リリースでは debian) のため、初回ログイン時に
# 変更を強制して既知パスワードのまま運用され続けるのを防ぐ
chroot "$ROOT" chage -d 0 debian
