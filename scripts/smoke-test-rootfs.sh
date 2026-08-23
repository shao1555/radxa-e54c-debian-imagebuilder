#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# rootfs.tar の回帰検査。tar の listing (+一部ファイル抽出) だけで検査するため、
# ビルド環境 (devcontainer) 不要でホスト/CI ランナーのどちらでも実行できる。
# 過去に実際に踏んだ回帰 (networkd 未 enable、resolv.conf 消失、
# カーネル未投入など) を最低ラインとして検査する。
set -euo pipefail

cd "$(dirname "$0")/.."
TOP="$PWD"
PLAN="out/meta/module-plan.json"
if [[ "${1:-}" == "--plan" ]]; then
	PLAN="$2"
	shift 2
fi
TAR="${1:-out/rootfs/build/rootfs.tar}"
[[ -f $TAR ]] || { echo "NG: rootfs.tar が無い: $TAR" >&2; exit 1; }
[[ -f $PLAN ]] || { echo "NG: module-plan が無い: $PLAN (make resolve)" >&2; exit 1; }

# rootfs artifact が現在の plan の module 入力から作られたこと (artifact digest)
# と、tar 実体が sidecar の記録と一致することを検証する。
# builtWithPlanDigest の不一致は再構築条件にしない (test のみの変更では
# rootfs を再利用できる)
python3 scripts/resolve-modules.py verify-sidecar --plan "$PLAN" \
	--rootfs "$TAR" --sidecar "$(dirname "$TAR")/rootfs.meta.json"

# 共通 helper (check / check_absent / enabled / tar_cat) と、モジュールテストへの
# 受け渡し (Issue #7 の契約)。listing は一度だけ生成して共有する
LISTING_TMP="$(mktemp)"
trap 'rm -f "$LISTING_TMP"' EXIT
tar -tvf "$TAR" > "$LISTING_TMP"
E54C_ROOTFS_TAR="$(readlink -f "$TAR")"
export E54C_ROOTFS_TAR
export E54C_ROOTFS_LISTING="$LISTING_TMP"
export E54C_TEST_LIB="$TOP/scripts/test-lib.sh"
# shellcheck source=test-lib.sh
source "$E54C_TEST_LIB"
listing="$(cat "$LISTING_TMP")"

# (利用目的依存の検査は各モジュールの tests/rootfs.sh に移行済み:
#  ssh / default-user / networkd / systemd-resolved / container-host /
#  incus / k3s。以下は framework/board invariant のみ)

# resolv.conf の安全 invariant: ビルドホスト由来の regular file と .bak を
# 成果物に残さない。resolved の有無によらず core final seal が保証する
# (symlink の最終ポリシーは systemd-resolved モジュールが所有・検査する)
check_absent "ビルドホスト resolv.conf の漏洩 (regular file)" '^-.* \./etc/resolv\.conf$'
check_absent "ビルドホスト DNS の漏洩 (.resolv.conf.systemd-resolved.bak)" \
	'\./etc/\.resolv\.conf\.systemd-resolved\.bak$'

# --- ブート (カーネル・DTB・extlinux) ---
# 通常ファイルも「^-(種別) + フルパス + 行末 $」で固定し、.bak/.old 等への
# 誤一致を防ぐ。実行が必要なものは実行ビット (^-rwx) まで確認する
check "カーネル (vmlinuz)"                 '^-.* \./boot/vmlinuz-[0-9][^ ]*$'
# vmlinuz は非圧縮の ARM64 Image であること。bindeb-pkg の既定 (Image.gz) に
# 戻ると vendor U-Boot 2017.09 は booti の gzip 展開に未対応でブート不能になる。
# 先頭 2 バイトが gzip magic (1f 8b) でなく、offset 56 に "ARM\x64" があること
vmlinuz_member="$(tar -tf "$TAR" | grep -E '^\./boot/vmlinuz-[0-9]' | head -1 || true)"
# head -c が先にパイプを閉じると tar が SIGPIPE になるため || true で受ける
# (od/tr は完走しており出力は完全)
vmlinuz_hdr="$(tar -xOf "$TAR" "$vmlinuz_member" 2> /dev/null | head -c 64 \
	| od -An -v -tx1 | tr -d ' \n' || true)"
if [[ ${vmlinuz_hdr:0:4} != "1f8b" && ${vmlinuz_hdr:112:8} == "41524d64" ]]; then
	echo "ok: vmlinuz が非圧縮の ARM64 Image (vendor U-Boot は gzip 非対応)"
else
	echo "NG: vmlinuz が非圧縮 ARM64 Image でない (先頭=${vmlinuz_hdr:0:4} magic@56=${vmlinuz_hdr:112:8})"
	fail=1
fi
check "initrd"                             '^-.* \./boot/initrd\.img-[0-9][^ ]*$'
check "E54C の DTB"                        '^-.* \./usr/lib/linux-image-[^ ]*/rockchip/rk3582-radxa-e54c\.dtb$'
check "extlinux.conf (u-boot-update 生成)" '^-.* \./boot/extlinux/extlinux\.conf$'
# 全 stanza に initrd 行があること (root=UUID は initramfs 必須。
# u-boot-update と update-initramfs の順序バグで実際に欠落した回帰の固定)
extlinux="$(tar -xOf "$TAR" ./boot/extlinux/extlinux.conf 2> /dev/null)"
n_linux="$(grep -c $'^\tlinux ' <<< "$extlinux" || true)"
n_initrd="$(grep -c $'^\tinitrd ' <<< "$extlinux" || true)"
if [[ "$n_linux" -gt 0 && "$n_linux" -eq "$n_initrd" ]]; then
	echo "ok: extlinux.conf の全 stanza に initrd 行がある ($n_linux/$n_linux)"
else
	echo "NG: extlinux.conf の initrd 行が不足 (linux=$n_linux initrd=$n_initrd)"
	fail=1
fi
check "/etc/kernel/cmdline"                '^-.* \./etc/kernel/cmdline$'
check "U-Boot 書き込みスクリプト (実行可)" '^-rwx.* \./usr/lib/u-boot/radxa-e54c/setup\.sh$'
# ビルドは Debian snapshot で解決するが、成果物の apt は live リポジトリを
# 参照すること (snapshot URL が残ると配備後の security update が止まる)
apt_sources="$(tar -xOf "$TAR" ./etc/apt/sources.list 2> /dev/null; \
	for f in $(tar -tf "$TAR" | grep -E '^\./etc/apt/sources\.list\.d/.+\.list$'); do \
		tar -xOf "$TAR" "$f" 2> /dev/null; done)"
if grep -q 'snapshot\.debian\.org' <<< "$apt_sources"; then
	echo "NG: 成果物の apt sources に snapshot URL が残っている"
	fail=1
else
	echo "ok: 成果物の apt sources に snapshot URL が無い"
fi
for want in ' trixie ' ' trixie-updates ' ' trixie-security '; do
	if grep -E "^deb https?://[^ ]*deb\.debian\.org/[^ ]+${want}" <<< "$apt_sources" > /dev/null; then
		echo "ok: live リポジトリ (${want// /}) が設定されている"
	else
		echo "NG: live リポジトリ (${want// /}) が無い"
		fail=1
	fi
done
# ビルド時の apt 設定 (Check-Valid-Until 無効化) が成果物に残っていないこと
# (残ると配備後の apt が期限切れ Release を受理する)
apt_conf="$(for f in $(tar -tf "$TAR" | grep -E '^\./etc/apt/apt\.conf\.d/.'); do \
	tar -xOf "$TAR" "$f" 2> /dev/null; done)"
if grep -qi 'Check-Valid-Until' <<< "$apt_conf"; then
	echo "NG: apt.conf.d に Check-Valid-Until の無効化が残っている"
	fail=1
else
	echo "ok: apt.conf.d にビルド時の apt 設定が残っていない"
fi

# Radxa deb は lock 固定の dpkg 投入だが、配備後の U-Boot 更新経路
# (リポジトリ設定 + keyring) は成果物に残っていること
check "radxa リポジトリの sources.list"    '\./etc/apt/sources\.list\.d/80-radxa-uboot\.list$'
check "radxa リポジトリの pin 設定"        '\./etc/apt/preferences\.d/radxa-uboot-only$'
check "radxa keyring"                      '\./usr/share/keyrings/radxa-archive-keyring\.gpg'

# microSD ブートの生命線。QEMU テストは virtio ディスクのため実 SD コントローラ
# (dw_mmc) を検証できず、ここで静的に固定する
check "dw_mmc-rockchip モジュール (microSD ブートに必要)" \
	"/dw_mmc-rockchip\\.ko(\\.(gz|xz|zst))?\$"
# rootfs をマウントする前段の initramfs にも収録されていること (モジュール deb に
# あっても initrd から漏れると microSD ブート不能。initrd は early cpio 連結 +
# zstd 圧縮のため lsinitramfs で内部を見る)
initrd_member="$(tar -tf "$TAR" | grep -E '^\./boot/initrd\.img-[0-9]' | head -1 || true)"
initrd_tmp="$(mktemp)"
# trap の再設定は先の trap を上書きするため、両方の一時ファイルを掃除する
trap 'rm -f "$initrd_tmp" "$LISTING_TMP"' EXIT
if ! command -v lsinitramfs > /dev/null; then
	echo "NG: lsinitramfs が無い (initramfs-tools-core を入れること。initrd 検査に必要)"
	fail=1
elif tar -xOf "$TAR" "$initrd_member" 2> /dev/null > "$initrd_tmp" \
	&& lsinitramfs "$initrd_tmp" \
		| grep -E '/dw_mmc-rockchip\.ko(\.(gz|xz|zst))?$' > /dev/null; then
	# grep -q は初一致でパイプを閉じ lsinitramfs が SIGPIPE 死する (pipefail で偽になる)
	echo "ok: initramfs に dw_mmc-rockchip が収録されている"
else
	echo "NG: initramfs に dw_mmc-rockchip が無い (microSD からブートできない)"
	fail=1
fi

# デバッグシンボル (linux-image-*-dbg) は ~500MiB あり軽量方針に反する
check_absent "カーネルのデバッグシンボルが入っていない" '\./usr/lib/debug/'

# --- ビルド環境の痕跡が無いこと ---
check_absent "/etc/machine-id が焼き込まれていない"          '\./etc/machine-id$'
check_absent "/var/lib/dbus/machine-id が焼き込まれていない" '\./var/lib/dbus/machine-id$'
# apt lists は正常な足場 (lock, partial/) 以外に何も残っていないこと。
# mirror 名でのパターン照合だと security/Radxa/変更後 mirror の index を見逃す
apt_residue="$(grep -E ' \./var/lib/apt/lists/.' <<< "$listing" \
	| grep -vE ' \./var/lib/apt/lists/(lock|partial/|auxfiles/)$' || true)"
if [[ -n $apt_residue ]]; then
	echo "NG: apt lists に index の残骸がある:"
	echo "$apt_residue" | head -5
	fail=1
else
	echo "ok: apt lists に index の残骸が無い"
fi

# --- モジュールの rootfs test (core 検査の後、plan の順、各テストは独立プロセス) ---
# modules/ は再探索しない: plan に記載されたテストだけを実行する。
# list-tests は出力前に containment / type / mode / digest を再検証し、
# stale / 改ざん plan なら失敗する。モジュールテストは追加のみ可能で、
# core invariant を無効化できない (fail は集約のみ)
# 各 module へは自分の解決済み config だけを渡す (plan 全体は渡さない)
CONFIG_DIR="$(mktemp -d)"
trap 'rm -f "$initrd_tmp" "$LISTING_TMP"; rm -rf "$CONFIG_DIR"' EXIT
python3 scripts/resolve-modules.py write-configs --plan "$PLAN" --output-dir "$CONFIG_DIR"
module_tests="$(python3 scripts/resolve-modules.py list-tests --plan "$PLAN" --phase rootfs)"
while IFS=$'\t' read -r mid t; do
	[[ -n $mid ]] || continue
	echo "module[$mid] rootfs test: $t"
	if E54C_MODULE_ID="$mid" E54C_MODULE_CONFIG="$CONFIG_DIR/$mid.json" \
		"$TOP/$t" 2>&1 | sed "s/^/module[$mid] /"; then
		:
	else
		echo "NG: module[$mid] の rootfs test が失敗 ($t)"
		fail=1
	fi
done <<< "$module_tests"

if ((fail)); then
	echo "smoke test: FAILED" >&2
	exit 1
fi
echo "smoke test: PASSED"
