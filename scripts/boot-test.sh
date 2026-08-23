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
# append 行はインデント形式 (タブ/空白) を問わず数え、console は append 行上
# でのみ数える (sed はタブ形式のみ書き換えるため、形式が変わればここで検出できる)
n_append="$(grep -cE '^[[:space:]]+append[[:space:]]' "$WORK/extlinux.conf" || true)"
n_console="$(grep -cE '^[[:space:]]+append[[:space:]].*console=ttyAMA0([[:space:]]|$)' \
	"$WORK/extlinux.conf" || true)"
if [[ $n_append -eq 0 || $n_append -ne $n_console ]]; then
	echo "エラー: extlinux.conf への console=ttyAMA0 追記に失敗 (append=$n_append console=$n_console)" >&2
	exit 1
fi
# 3. 容量拡張の検証: +2GiB してからブートし、ゲスト内で拡張結果を確認する
qemu-img resize -f raw "$IMG" +2G

# --- boot テスト bundle の組み立て (Issue #7) ---
# core 検査 + モジュールの boot テスト + 共通 lib + dispatcher を 1 つの tar に
# まとめ、シリアル転送は 1 回のまま各テストを独立プロセスで実行する
BUNDLE="$WORK/boot-tests"
mkdir -p "$BUNDLE/modules"
cp "$TOP/scripts/boot-test-lib.sh" "$BUNDLE/test-lib.sh"
cp "$TOP/scripts/boot-check.sh" "$BUNDLE/core.sh"
cp "$TOP/scripts/boot-test-run.sh" "$BUNDLE/run.sh"
# process substitution だと resolver の失敗が while に伝播しないため、
# 先に変数へ受けて set -e で止まるようにする (rootfs runner と同じ理由)。
# コピー名は宣言順の連番を前置し、同名 basename の test が上書きされて
# 実行漏れになるのを防ぐ (dispatcher は名前の辞書順で実行する)
module_boot_tests="$(python3 "$TOP/scripts/resolve-modules.py" --json | python3 -c "
import json, sys
for m in json.load(sys.stdin):
    for i, t in enumerate(m['tests'].get('boot', [])):
        print(f\"{m['id']}\t{i:02d}\t{t}\")")"
while IFS=$'\t' read -r mid idx t; do
	[[ -n $mid ]] || continue
	echo "module[$mid] boot test: ${t#"$TOP"/}"
	mkdir -p "$BUNDLE/modules/$mid"
	cp "$t" "$BUNDLE/modules/$mid/${idx}-$(basename "$t")"
done <<< "$module_boot_tests"
tar -cf "$WORK/boot-tests.tar" -C "$BUNDLE" .

expect "$TOP/scripts/boot-test.expect" "$IMG" "$WORK/boot-tests.tar" "$SSH_PORT"
