#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""config.yaml + packages.txt + files/ + hooks/ から bdebstrap 設定を生成する。

rsdk の rootfs.jsonnet に相当するが、単一ボード・単一エディションなので
jsonnet を使わず素直な Python で組み立てる。
"""
import sys
import yaml
from pathlib import Path

TOP = Path(__file__).resolve().parent.parent
cfg = yaml.safe_load((TOP / "config.yaml").read_text())
out_dir = Path(sys.argv[1]).resolve()  # 例: out/rootfs

packages = []
for line in (TOP / "packages.txt").read_text().splitlines():
    line = line.split("#", 1)[0].strip()
    if line:
        packages.append(line)

deb = cfg["debian"]
ub = cfg["uboot"]
suite = deb["suite"]

setup_hooks = [
    # updates / security を有効化 (rsdk と同じ流儀)
    f'head -n1 "$1/etc/apt/sources.list" | sed -E "s/({suite})/\\1-updates/" '
    f'> "$1/etc/apt/sources.list.d/50-{suite}-updates.list"',
    f'head -n1 "$1/etc/apt/sources.list" | sed -E -e "s/({suite})/\\1-security/" '
    f'-e "s|/debian |/debian-security |" > "$1/etc/apt/sources.list.d/50-{suite}-security.list"',
    # Radxa リポジトリ (U-Boot 専用に pin する)。
    # keyring パッケージ自体がこのリポジトリから入る鶏卵問題があるため、
    # build-rootfs.sh が取得した keyring ファイルを先に target へ直接コピーし、
    # 最初から signed-by で参照する (apt 3.0/sqv は target 内の鍵しか見ない)
    'mkdir -p "$1/usr/share/keyrings"',
    # canonical 名は年次 keyring への symlink のため、実体ごとまとめてコピーする
    f'cp -a "{TOP}"/out/rootfs/keyrings/radxa-archive-keyring*.gpg "$1/usr/share/keyrings/"',
    f'echo "deb [signed-by=/usr/share/keyrings/radxa-archive-keyring.gpg] '
    f'{ub["apt_repo"]} {ub["apt_suite"]} main" > "$1/etc/apt/sources.list.d/80-radxa-uboot.list"',
    'mkdir -p "$1/etc/apt/preferences.d"',
    'printf "Package: *\\nPin: origin radxa-repo.github.io\\nPin-Priority: -1\\n\\n'
    'Package: u-boot-* radxa-archive-keyring\\nPin: origin radxa-repo.github.io\\n'
    'Pin-Priority: 500\\n" > "$1/etc/apt/preferences.d/radxa-uboot-only"',
]

customize_hooks = [
    # 自前ビルドのカーネル deb (out/debs) を最初にインストールする
    f'mkdir -p "$1/tmp/kernel-debs" && cp "{TOP}"/out/debs/linux-image-*.deb '
    f'"{TOP}"/out/debs/linux-headers-*.deb "$1/tmp/kernel-debs/" 2>/dev/null || true',
    'chroot "$1" sh -c "dpkg -i /tmp/kernel-debs/*.deb || '
    'DEBIAN_FRONTEND=noninteractive apt-get -f install -y" && rm -rf "$1/tmp/kernel-debs"',
    # files/ overlay をそのまま重ねる
    f'if [ -d "{TOP}/files" ]; then cp -a "{TOP}/files/." "$1/"; fi',
    # hostname
    f'echo "{cfg["image"]["hostname"]}" > "$1/etc/hostname"',
    f'echo "127.0.1.1\t{cfg["image"]["hostname"]}" >> "$1/etc/hosts"',
    # 自作フック (chroot 外から $1 を渡して実行)
    f'for h in "{TOP}"/hooks/customize.d/*.sh; do [ -e "$h" ] && bash "$h" "$1"; done',
    # systemd-networkd の有効化。Debian は既定で enable しないため、
    # files/etc/systemd/network/*.network はこれが無いと一切機能しない
    # (= 初回起動時に lan1 が DHCP せず SSH 到達不能になる)
    'chroot "$1" systemctl enable systemd-networkd.service systemd-networkd.socket',
    # ブート用カーネル引数。root= は build-image.sh がイメージ作成時に UUID を注入する。
    # u-boot-update が /etc/kernel/cmdline を参照するよう /etc/default/u-boot を配線して
    # おくことで、実機での以後のカーネル更新でも root= が維持される
    'echo "rw console=tty1 console=ttyS2,1500000n8" > "$1/etc/kernel/cmdline"',
    'echo \'U_BOOT_PARAMETERS="$(cat /etc/kernel/cmdline)"\' >> "$1/etc/default/u-boot"',
    # カーネル導入後の起動整備
    'chroot "$1" u-boot-update || true',
    'chroot "$1" update-initramfs -c -k all || true',
]

config = {
    "mmdebstrap": {
        "architectures": ["arm64"],
        "suite": suite,
        "target": "rootfs.tar",
        "mode": "root",
        "variant": deb.get("variant", "apt"),
        "mirrors": [deb["mirror"]],
        "components": deb["components"],
        "packages": [
            "init", "sudo", "systemd-boot", "initramfs-tools", "zstd",
            "u-boot-menu",  # u-boot-update (extlinux.conf 生成)
            "radxa-archive-keyring",
            *ub["packages"],
            *packages,
        ],
        "setup-hooks": setup_hooks,
        "customize-hooks": customize_hooks,
        "cleanup-hooks": [
            # ビルドホストの DNS 設定 (mmdebstrap が入れる resolv.conf と、
            # systemd-resolved postinst が退避した .bak) を除去し、resolved の
            # stub への symlink に置き換える。単に削除するだけだと初回起動時に
            # glibc が /etc/resolv.conf を見つけられず DNS 解決が壊れる
            'rm -f "$1/etc/resolv.conf" "$1/etc/.resolv.conf.systemd-resolved.bak"',
            'ln -s ../run/systemd/resolve/stub-resolv.conf "$1/etc/resolv.conf"',
            'rm -rf "$1/var/lib/apt/lists"/*',
            'rm -f "$1/etc/machine-id" "$1/var/lib/dbus/machine-id"',
        ],
    },
}

out_dir.mkdir(parents=True, exist_ok=True)
(out_dir / "bdebstrap.yaml").write_text(yaml.safe_dump(config, sort_keys=False, width=200))
print(f"wrote {out_dir}/bdebstrap.yaml ({len(packages)} extra packages)")
