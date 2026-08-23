#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# rootfs.tar から起動可能な GPT イメージを組み立てる。
# パーティションレイアウトと U-Boot 書き込みは Radxa rsdk の build-image と同一方式
# (docs/04-image.md 参照)。実行環境: Linux (CI)。必要: guestfish (libguestfs-tools),
# gdisk (sgdisk), parted, python3-yaml, xz-utils
set -euo pipefail

# KVM が無い環境 (macOS の Docker 等) では libguestfs が gic-version=host で
# 起動失敗するため、TCG を明示する (検証済み: アプライアンス起動 ~10 秒)
export LIBGUESTFS_BACKEND=direct
[[ -e /dev/kvm ]] || export LIBGUESTFS_BACKEND_SETTINGS=force_tcg

cd "$(dirname "$0")/.."
TOP="$PWD"
PLAN="$TOP/out/meta/module-plan.json"
if [[ "${1:-}" == "--plan" ]]; then
	PLAN="$2"
	shift 2
fi
ROOTFS="$TOP/out/rootfs/build/rootfs.tar"
[[ -f $ROOTFS ]] || { echo "rootfs.tar が無い。先に build-rootfs.sh を実行" >&2; exit 1; }
[[ -f $PLAN ]] || { echo "エラー: module-plan が無い: $PLAN (make resolve)" >&2; exit 1; }

# rootfs が現在の plan の module 入力から作られたこと + tar 実体の整合を検証する
# (image job は module source を実行しないため、path/content の再検証は不要)
python3 scripts/resolve-modules.py verify-sidecar --plan "$PLAN" \
	--rootfs "$ROOTFS" --sidecar "$TOP/out/rootfs/build/rootfs.meta.json"

name="$(python3 -c "import yaml;print(yaml.safe_load(open('config.yaml'))['image']['name'])")"
suite="$(python3 -c "import yaml;print(yaml.safe_load(open('config.yaml'))['debian']['suite'])")"
size_gb="$(python3 -c "import yaml;print(yaml.safe_load(open('config.yaml'))['image']['size_gb'])")"
VERSION="${VERSION:-dev}"
IMG="$TOP/out/${name}_${suite}_${VERSION}.img"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# rootfs から U-Boot の書き込みスクリプト (u-boot-radxa-e54c 由来) を取り出しておく
tar -C "$TMP" -xf "$ROOTFS" ./usr/lib/u-boot 2>/dev/null || \
	tar -C "$TMP" -xf "$ROOTFS" usr/lib/u-boot

guestfish <<EOF
!echo "Creating image..."
disk-create $IMG raw ${size_gb}G
add-drive $IMG format:raw
run

part-init /dev/sda gpt
# 先頭 16MiB は U-Boot 用に空ける (idbloader @ sec64 / u-boot.itb @ sec16384)
part-add /dev/sda primary 32768 65535
part-add /dev/sda primary 65536 679935
part-add /dev/sda primary 679936 -34
part-set-bootable /dev/sda 2 true
part-set-bootable /dev/sda 3 true
part-set-gpt-type /dev/sda 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B
part-set-gpt-type /dev/sda 3 0FC63DAF-8483-4772-8E79-3D69D8477DE4
# GPT の legacy_boot 属性 (bit2 = 4)。U-Boot は bootable 印のある
# パーティションだけを extlinux スキャンの対象にする (QEMU テストで検出。
# rsdk も同じ指定を行っている)
part-set-gpt-attributes /dev/sda 2 4
part-set-gpt-attributes /dev/sda 3 4

mkfs vfat /dev/sda1 label:config
mkfs vfat /dev/sda2 label:efi

echo "rootfs ext4: U-Boot の ext4 ドライバが読めないフィーチャーを無効化して作成"
# trixie の e2fsprogs は orphan_file と metadata_csum_seed (incompat) を既定で
# 有効にするが、U-Boot (vendor 2017.09 / mainline とも) はこれを読めず、
# /boot/extlinux が見つからずブート不能になる (QEMU ブートテストで実際に検出)
mkfs ext4 /dev/sda3 label:rootfs features:^orphan_file,^metadata_csum_seed

mount /dev/sda3 /
mkdir-p /config
mkdir-p /boot/efi
mount /dev/sda1 /config
mount /dev/sda2 /boot/efi

!echo "Deploying rootfs..."
tar-in $ROOTFS / xattrs:true

copy-out /etc/kernel/cmdline $TMP
copy-out /boot/extlinux/extlinux.conf $TMP

blkid /dev/sda1 | grep "^UUID:" | cut -d " " -f 2 | xargs printf "UUID=%s /config vfat defaults,x-systemd.automount 0 2\n" > $TMP/fstab
blkid /dev/sda2 | grep "^UUID:" | cut -d " " -f 2 | xargs printf "UUID=%s /boot/efi vfat defaults,x-systemd.automount 0 2\n" >> $TMP/fstab
blkid /dev/sda3 | grep "^UUID:" | cut -d " " -f 2 | xargs printf "UUID=%s / ext4 defaults,x-systemd.growfs 0 1\n" >> $TMP/fstab
blkid /dev/sda3 | grep "^UUID:" | cut -d " " -f 2 > $TMP/rootfs_uuid
!sed -i -E -e "s/([[:space:]]*root=[^[:space:]]*[[:space:]]*)/ /g" -e "s/(append[[:space:]]+)/append root=UUID=\$(cat $TMP/rootfs_uuid) /g" $TMP/extlinux.conf
!sed -i -E -e "s/([[:space:]]*root=[^[:space:]]*[[:space:]]*)/ /g" -e "s/^/root=UUID=\$(cat $TMP/rootfs_uuid) /" $TMP/cmdline
copy-in $TMP/fstab /etc/
copy-in $TMP/extlinux.conf /boot/extlinux/
copy-in $TMP/cmdline /etc/kernel/

!echo "Shrinking rootfs..."
umount-all
resize2fs-M /dev/sda3
tune2fs-l /dev/sda3 | cat > $TMP/tune2fs
sync
shutdown
EOF

# パーティションをファイルシステム実サイズまで切り詰め、イメージも truncate。
# parted (---pretend-input-tty) と sgdisk -ge (切り詰め直後は backup GPT が無い)
# の exit code は当てにならないため || true で流し、代わりに直後の検証で
# 最終状態を厳密に確認して失敗させる
start=$(sgdisk -i 3 "$IMG" | awk '/First sector:/{print $3}')
bc_count=$(awk '/Block count:/{print $3}' "$TMP/tune2fs")
bc_size=$(awk '/Block size:/{print $3}' "$TMP/tune2fs")
end_bytes=$(( start * 512 + bc_count * bc_size ))
printf "resizepart 3\n%sB\nyes\n" "$end_bytes" | parted ---pretend-input-tty "$IMG" > /dev/null 2>&1 || true
last=$(sgdisk -i 3 "$IMG" | awk '/Last sector:/{print $3}')
truncate --size=$(( (last + 34) * 512 )) "$IMG"
sgdisk -ge "$IMG" > /dev/null 2>&1 || true

# U-Boot の書き込み (u-boot-radxa-e54c の setup.sh に委譲)
chmod +x "$TMP/usr/lib/u-boot/radxa-e54c/setup.sh"
"$TMP/usr/lib/u-boot/radxa-e54c/setup.sh" update_bootloader "$IMG" 512

# --- 最終検証 (どれか 1 つでも失敗したらリリースさせない) ---
echo "Verifying image..."

# sgdisk -ge / U-Boot 書き込み後の「最終状態」を検証するため、終端を再取得する
last=$(sgdisk -i 3 "$IMG" | awk '/Last sector:/{print $3}')

# 1. 縮小が計算どおり行われたか (parted の失敗検出)。
#    parted の "<N>B" は「そのバイトを含むセクタまで」のインクルーシブ丸めの
#    ため、最小値ちょうどか +1 セクタになる (それ以外は縮小失敗)
min_last=$(( end_bytes / 512 - 1 ))
if (( last < min_last || last > min_last + 1 )); then
	echo "NG: パーティション縮小に失敗 (end=$last expected=$min_last..$(( min_last + 1 )))" >&2
	exit 1
fi

# 2. イメージサイズ = パーティション終端 + backup GPT (34 sector) ちょうどか、
#    かつ確保サイズ (${size_gb}G) より実際に小さくなっているか
actual_size=$(stat -c %s "$IMG")
expected_size=$(( (last + 34) * 512 ))
if [[ "$actual_size" -ne "$expected_size" ]]; then
	echo "NG: イメージサイズ不一致 (actual=$actual_size expected=$expected_size)" >&2
	exit 1
fi
if (( actual_size >= size_gb * 1024 * 1024 * 1024 )); then
	echo "NG: イメージが縮小されていない (${actual_size} bytes)" >&2
	exit 1
fi

# 3. GPT の整合性 (sgdisk -ge が backup GPT を末尾に再配置できたか)
LC_ALL=C sgdisk -v "$IMG" > "$TMP/sgdisk-v" 2>&1 || true
if ! grep -qE '^No problems found\.' "$TMP/sgdisk-v"; then
	echo "NG: GPT に問題がある:" >&2
	cat "$TMP/sgdisk-v" >&2
	exit 1
fi

# 4. GPT の legacy_boot 属性 (bit2)。QEMU ブートテストはホストの u-boot-qemu で
#    ブートするため、将来の U-Boot が非 bootable パーティションも走査するように
#    なると欠落を検出できない。実機 (vendor U-Boot) の要件として静的に固定する
for p in 2 3; do
	attr="$(LC_ALL=C sgdisk -i "$p" "$IMG" | awk '/Attribute flags:/{print $3}')"
	if (( (16#${attr:-0} & 4) == 0 )); then
		echo "NG: パーティション $p に legacy_boot 属性 (bit2) が無い (attr=${attr:-取得失敗})" >&2
		exit 1
	fi
done

# 5. U-Boot が読めない ext4 フィーチャーが紛れ込んでいないこと
#    (mke2fs.conf の既定変更などで再発し得るため、成果物で確認する)
feat="$(guestfish --ro -a "$IMG" run : tune2fs-l /dev/sda3 | grep -i '^Filesystem features:')"
if grep -qE 'orphan_file|metadata_csum_seed' <<< "$feat"; then
	echo "NG: U-Boot 非互換の ext4 フィーチャーがある: $feat" >&2
	exit 1
fi

# 6. rootfs のファイルシステム整合性 (--ro なのでイメージは変更されない)
fsck_status="$(guestfish --ro -a "$IMG" run : fsck ext4 /dev/sda3 | tail -1)"
if [[ "$fsck_status" != "0" ]]; then
	echo "NG: e2fsck がエラーを報告 (status=$fsck_status)" >&2
	exit 1
fi
echo "Image verification passed."

xz -T0 -f "$IMG"
echo "done: $IMG.xz"
