#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# ビルド済みイメージを QEMU (U-Boot qemu_arm64 → extlinux → 実カーネル) で
# ブートし、ゲスト内検査 (scripts/boot-check.sh) を実行する。
# リリース成果物の実ブートパス (extlinux.conf / initrd / root=UUID) と
# 容量拡張 (growroot + x-systemd.growfs)、ネットワーク (DHCP / DNS / 外部 TCP)、
# ホストからの実 SSH ログインを検証する。
# 実行環境: Linux (devcontainer / CI)。必要: qemu-system-arm, qemu-utils,
#           u-boot-qemu, expect, openssh-client, libguestfs-tools, xz-utils
set -euo pipefail

cd "$(dirname "$0")/.."
TOP="$PWD"

# 入力: 引数 or out/ の最新 .img.xz
IMG_XZ="${1:-$(ls -t "$TOP"/out/*.img.xz 2> /dev/null | head -1)}"
[[ -f ${IMG_XZ:-} ]] || { echo "エラー: イメージ (.img.xz) が無い。先に make image" >&2; exit 1; }
echo "boot test 対象: $IMG_XZ"

# ホスト→ゲストの SSH ログイン試験に使う転送ポート (127.0.0.1 のみ bind)
SSH_PORT="${BOOT_TEST_SSH_PORT:-2222}"

export LIBGUESTFS_BACKEND=direct
[[ -e /dev/kvm ]] || export LIBGUESTFS_BACKEND_SETTINGS=force_tcg

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
IMG="$WORK/test.img"
xz -dc "$IMG_XZ" > "$IMG"

# --- QEMU 用の試験調整 (使い捨てコピーに対してのみ行う) ---
# 1. シリアルコンソール: 実機は ttyS2 だが QEMU virt は ttyAMA0 のため、
#    extlinux.conf の append 行末尾に console=ttyAMA0 を追記する
#    (末尾 = /dev/console になり、getty もここに立つ)
# 2. NIC: 製品設定は実機の lan1 のみ DHCP のため、QEMU の virtio NIC (en*) 用の
#    .network を試験専用に注入する (製品側の files/ は変更しない)
cat > "$WORK/99-boottest.network" << 'EOF'
# QEMU ブートテスト専用 (boot-test.sh が使い捨てコピーに注入する)
[Match]
Name=en*

[Network]
DHCP=yes
EOF
guestfish -a "$IMG" << EOF
run
mount /dev/sda3 /
download /boot/extlinux/extlinux.conf $WORK/extlinux.conf
!sed -i -E 's/^(\tappend .*)$/\1 console=ttyAMA0/' $WORK/extlinux.conf
upload $WORK/extlinux.conf /boot/extlinux/extlinux.conf
upload $WORK/99-boottest.network /etc/systemd/network/99-boottest.network
EOF
# sed が本当に全 stanza に効いたか確認する (書式変更で 0 置換のまま進むと、
# コンソール無しで 900 秒待った末に不明瞭なタイムアウトになる)
n_append="$(grep -c $'^\tappend ' "$WORK/extlinux.conf" || true)"
n_console="$(grep -c 'console=ttyAMA0' "$WORK/extlinux.conf" || true)"
if [[ $n_append -eq 0 || $n_append -ne $n_console ]]; then
	echo "エラー: extlinux.conf への console=ttyAMA0 追記に失敗 (append=$n_append console=$n_console)" >&2
	exit 1
fi
# 3. 容量拡張の検証: +2GiB してからブートし、ゲスト内で拡張結果を確認する
qemu-img resize -f raw "$IMG" +2G

expect "$TOP/scripts/boot-test.expect" "$IMG" "$TOP/scripts/boot-check.sh" "$SSH_PORT"
