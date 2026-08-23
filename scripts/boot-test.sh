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
# integration test であり、ログイン情報 (username / requirePasswordChange /
# 初期パスワードの source 環境変数名) を検証済み consumer API (login-config)
# から取得する。default-user が選択されていない構成ではログイン手段を仮定
# できないため、黙って実行せず明示的に失敗させる (verb 側が
# "core login harness requires an access provider" で die する)
login_config="$(python3 "$TOP/scripts/resolve-modules.py" login-config --plan "$PLAN")"
IFS=$'\t' read -r login_user require_change pw_src <<< "$login_config"

# 初期パスワードの値は plan に含まれない (設計)。build と同じ provider
# (requiredSecrets の source 環境変数) から取得する: build に渡した値と
# harness が試す値が乖離しない。ローカルは .env、CI は workflow の env が設定する
if [[ -f "$TOP/.env" ]]; then
	# shellcheck source=/dev/null
	source "$TOP/.env"
fi
[[ -n $pw_src ]] || { echo "エラー: plan に initial-password の secret reference が無い" >&2; exit 1; }
if [[ ! -v $pw_src ]]; then
	echo "エラー: $pw_src が未設定です (login harness が初期パスワードを取得できない)。" >&2
	echo "  ローカル: cp .env.example .env して $pw_src を設定 (CI は workflow が設定)" >&2
	exit 1
fi
# 値は argv に載せない (プロセス一覧から見えるため)。0600 の一時ファイルに
# 書き、expect にはパスだけを渡す
pw_file="$WORK/initial-password"
(umask 077 && printf '%s' "${!pw_src}" > "$pw_file")
unset "$pw_src"

expect "$TOP/scripts/boot-test.expect" "$IMG" "$WORK/boot-tests.tar" "$SSH_PORT" \
	"$login_user" "$pw_file" "$require_change"
