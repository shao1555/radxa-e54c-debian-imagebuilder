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

PLAN="$TOP/out/meta/module-plan.json"
if [[ "${1:-}" == "--plan" ]]; then
	PLAN="$2"
	shift 2
fi
[[ -f $PLAN ]] || { echo "エラー: module-plan が無い: $PLAN (make resolve)" >&2; exit 1; }

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
mkdir -p "$BUNDLE/modules" "$BUNDLE/config"
cp "$TOP/scripts/boot-test-lib.sh" "$BUNDLE/test-lib.sh"
cp "$TOP/scripts/boot-check.sh" "$BUNDLE/core.sh"
cp "$TOP/scripts/boot-test-run.sh" "$BUNDLE/run.sh"
# 各 module の解決済み config を bundle に含める (dispatcher が該当 module の
# test にだけ E54C_MODULE_CONFIG を設定する。test 実行対象の modules/ とは
# 別ディレクトリに置き、config が test として実行されないようにする)
python3 "$TOP/scripts/resolve-modules.py" write-configs --plan "$PLAN" \
	--output-dir "$BUNDLE/config"
# modules/ は再探索しない: plan に記載された boot test だけを bundle に入れる。
# list-tests は出力前に containment / type / mode / digest を再検証する
# (stale / 改ざん plan なら失敗)。変数受けで失敗を set -e に伝播させる。
# コピー名は宣言順の連番を前置し、同名 basename の test が上書きされて
# 実行漏れになるのを防ぐ (dispatcher は名前の辞書順で実行する)
module_boot_tests="$(python3 "$TOP/scripts/resolve-modules.py" list-tests \
	--plan "$PLAN" --phase boot | awk -F'\t' '
	{ if ($1 != prev) { i = 0; prev = $1 }; printf "%s\t%02d\t%s\n", $1, i++, $2 }')"
while IFS=$'\t' read -r mid idx t; do
	[[ -n $mid ]] || continue
	echo "module[$mid] boot test: $t"
	mkdir -p "$BUNDLE/modules/$mid"
	cp "$TOP/$t" "$BUNDLE/modules/$mid/${idx}-$(basename "$t")"
done <<< "$module_boot_tests"
tar -cf "$WORK/boot-tests.tar" -C "$BUNDLE" .

# core login harness は「この成果物へ既定ユーザーでログインできること」の
# integration test であり、default-user の解決済み config (username /
# requirePasswordChange) を検証済み consumer API (module-config) から取得する。
# default-user が選択されていない構成ではログイン手段を仮定できないため、
# 黙って実行せず明示的に失敗させる (別の access provider は profile 導入時に設計)
du_config="$(python3 "$TOP/scripts/resolve-modules.py" module-config \
	--plan "$PLAN" --module default-user 2> /dev/null)" || {
	echo "エラー: core login harness requires an access provider" >&2
	echo "  (default-user モジュールが plan に含まれていない)" >&2
	exit 1
}
login_user="$(python3 -c "import json, sys; print(json.loads(sys.argv[1])['username'])" "$du_config")"
require_change="$(python3 -c "import json, sys; print(str(json.loads(sys.argv[1])['requirePasswordChange']).lower())" "$du_config")"
# 初期パスワードの値は plan に含まれない (設計)。harness は既定 debian を使い、
# 変更したビルドでは BOOT_TEST_PASSWORD で上書きする
BOOT_TEST_PASSWORD="${BOOT_TEST_PASSWORD:-debian}"

expect "$TOP/scripts/boot-test.expect" "$IMG" "$WORK/boot-tests.tar" "$SSH_PORT" \
	"$login_user" "$BOOT_TEST_PASSWORD" "$require_change"
