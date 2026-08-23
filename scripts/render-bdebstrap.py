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
components = " ".join(deb["components"])

# ビルド時のパッケージ解決は dependencies.lock.yaml の snapshot に固定する。
# 生成された rootfs の sources.list は cleanup で live リポジトリに書き戻す
# (配備後の security update を妨げない)
lock = yaml.safe_load((TOP / "dependencies.lock.yaml").read_text())
snap = lock["debian"]["snapshot"]
sec_snap = lock["debian"]["security_snapshot"]
snap_main = f"https://snapshot.debian.org/archive/debian/{snap}/"
snap_sec = f"https://snapshot.debian.org/archive/debian-security/{sec_snap}/"
# live のミラー (config.yaml)。security は Debian の標準命名から導出する
live_main = deb["mirror"].rstrip("/")
live_sec = live_main.rsplit("/", 1)[0] + "/debian-security"

customize_hooks = [
    # 自前ビルドのカーネル deb (out/debs) を最初にインストールする
    # カーネル deb の存在は build-rootfs.sh が事前検証済み (無ければここに来ない)。
    # コピー失敗は握りつぶさず、そのままビルドを失敗させる。
    # -dbg (デバッグシンボル ~500MiB) は「軽量」方針に反するため除外する
    f'mkdir -p "$1/tmp/kernel-debs" && cp "{TOP}"/out/debs/linux-image-*.deb '
    f'"{TOP}"/out/debs/linux-headers-*.deb "$1/tmp/kernel-debs/" && '
    'rm -f "$1/tmp/kernel-debs/"linux-image-*-dbg_*.deb',
    # dpkg -i の失敗を apt-get -f が依存解決して完了させるのは正常系だが、
    # 最終的にカーネルが本当に入ったか (/boot/vmlinuz-*) を必ず確認する
    'chroot "$1" sh -c "dpkg -i /tmp/kernel-debs/*.deb || '
    'DEBIAN_FRONTEND=noninteractive apt-get -f install -y" && rm -rf "$1/tmp/kernel-debs"',
    'ls "$1"/boot/vmlinuz-* > /dev/null 2>&1 || '
    '{ echo "エラー: カーネルが rootfs にインストールされていない" >&2; exit 1; }',
    # headers も apt-get -f が削除して「成功」する可能性があるため実在を確認する
    'ls -d "$1"/usr/src/linux-headers-* > /dev/null 2>&1 || '
    '{ echo "エラー: linux-headers が rootfs にインストールされていない" >&2; exit 1; }',
    # Radxa の deb (keyring / U-Boot)。apt 解決ではなく dependencies.lock.yaml で
    # 固定した deb (build-rootfs.sh が取得・sha256 検証済み) を dpkg で投入する。
    # dpkg -i は全 unpack 後にまとめて configure するため、メタパッケージと実体を
    # 1 回で入れられる
    f'mkdir -p "$1/tmp/radxa-debs" && cp "{TOP}"/out/rootfs/radxa-debs/*.deb "$1/tmp/radxa-debs/"',
    'chroot "$1" sh -c "dpkg -i /tmp/radxa-debs/*.deb" && rm -rf "$1/tmp/radxa-debs"',
    # U-Boot の書き込みスクリプト (build-image.sh が使う) と keyring の実在を確認
    'test -x "$1/usr/lib/u-boot/radxa-e54c/setup.sh" || '
    '{ echo "エラー: u-boot deb の投入に失敗 (setup.sh が無い)" >&2; exit 1; }',
    'test -e "$1/usr/share/keyrings/radxa-archive-keyring.gpg" || '
    '{ echo "エラー: radxa keyring の投入に失敗" >&2; exit 1; }',
    # 配備後の U-Boot 更新経路として radxa リポジトリを設定しておく
    # (ビルド時の apt はこのリポジトリに一切触れない。U-Boot 専用に pin する)
    f'echo "deb [signed-by=/usr/share/keyrings/radxa-archive-keyring.gpg] '
    f'{ub["apt_repo"]} {ub["apt_suite"]} main" > "$1/etc/apt/sources.list.d/80-radxa-uboot.list"',
    'mkdir -p "$1/etc/apt/preferences.d"',
    'printf "Package: *\\nPin: origin radxa-repo.github.io\\nPin-Priority: -1\\n\\n'
    'Package: u-boot-* radxa-archive-keyring\\nPin: origin radxa-repo.github.io\\n'
    'Pin-Priority: 500\\n" > "$1/etc/apt/preferences.d/radxa-uboot-only"',
    # files/ overlay をそのまま重ねる
    f'if [ -d "{TOP}/files" ]; then cp -a "{TOP}/files/." "$1/"; fi',
    # hostname
    f'echo "{cfg["image"]["hostname"]}" > "$1/etc/hostname"',
    f'echo "127.0.1.1\t{cfg["image"]["hostname"]}" >> "$1/etc/hosts"',
    # 自作フック (chroot 外から $1 を渡して実行)
    f'for h in "{TOP}"/hooks/customize.d/*.sh; do [ -e "$h" ] && bash "$h" "$1"; done',
    # デフォルトユーザーの作成。パスワードは bdebstrap.yaml (リリースに同梱される)
    # に値を埋め込まず、フック実行時の環境変数 $DEFAULT_PASSWORD を参照する
    # (build-rootfs.sh が未設定を検知して早期に失敗させる)
    'chroot "$1" useradd -m -s /bin/bash -G sudo debian',
    # dash の echo は \n 等を解釈してしまうため、固定書式の printf を使う
    # (CR/LF を含む値は build-rootfs.sh が事前拒否する)
    'printf \'%s:%s\\n\' debian "$DEFAULT_PASSWORD" | chroot "$1" chpasswd',
    # 初期パスワードは周知の値 (リリースでは debian) のため、初回ログイン時に
    # 変更を強制して既知パスワードのまま運用され続けるのを防ぐ
    'chroot "$1" chage -d 0 debian',
    # SSH ホスト鍵の初回起動生成は trixie 標準の sshd-keygen.service に任せる
    # (ConditionFirstBoot=yes。machine-id を cleanup で消すため初回起動で発動する。
    #  独自 unit を足すと並列実行の競合になるため追加してはいけない)
    # systemd-networkd の有効化。Debian は既定で enable しないため、
    # files/etc/systemd/network/*.network はこれが無いと一切機能しない
    # (= 初回起動時に lan1 が DHCP せず SSH 到達不能になる)
    'chroot "$1" systemctl enable systemd-networkd.service systemd-networkd.socket',
    # ブート用カーネル引数。root= は build-image.sh がイメージ作成時に UUID を注入する。
    # u-boot-update が /etc/kernel/cmdline を参照するよう /etc/default/u-boot を配線して
    # おくことで、実機での以後のカーネル更新でも root= が維持される
    # loglevel=5: auditd 不在時の kernel audit 記録 (NOTICE) 等がシリアル
    # コンソールを洪水にするのを防ぐ (警告/エラーと systemd のブート表示は残る)
    'echo "rw loglevel=5 console=tty1 console=ttyS2,1500000n8" > "$1/etc/kernel/cmdline"',
    'echo \'U_BOOT_PARAMETERS="$(cat /etc/kernel/cmdline)"\' >> "$1/etc/default/u-boot"',
    # カーネル導入後の起動整備。initramfs を先に確定させてから extlinux.conf を
    # 生成する (逆順だと initrd 行が欠けた extlinux.conf になり得る)。
    # 失敗は握りつぶさず、成果物 (initrd / extlinux.conf) の実在まで確認する
    'chroot "$1" update-initramfs -c -k all',
    'chroot "$1" u-boot-update',
    'ls "$1"/boot/initrd.img-* > /dev/null 2>&1 || '
    '{ echo "エラー: initrd が生成されていない" >&2; exit 1; }',
    'test -s "$1/boot/extlinux/extlinux.conf" || '
    '{ echo "エラー: extlinux.conf が生成されていない" >&2; exit 1; }',
    'grep -q "initrd" "$1/boot/extlinux/extlinux.conf" || '
    '{ echo "エラー: extlinux.conf に initrd 行が無い (起動不能になる)" >&2; exit 1; }',
]

config = {
    "mmdebstrap": {
        "architectures": ["arm64"],
        "suite": suite,
        "target": "rootfs.tar",
        "mode": "root",
        "variant": deb.get("variant", "apt"),
        # スペースを含む要素は sources.list の行として扱われる (mmdebstrap の仕様)。
        # main/updates/security の 3 系統すべてを snapshot に固定する
        "mirrors": [
            f"deb {snap_main} {suite} {components}",
            f"deb {snap_main} {suite}-updates {components}",
            f"deb {snap_sec} {suite}-security {components}",
        ],
        # snapshot の Release は Valid-Until が過去日になり得るため無効化する
        "aptopts": ['Acquire::Check-Valid-Until "false"'],
        "components": deb["components"],
        "packages": [
            # login: trixie では Essential でなくなり variant=apt に含まれない。
            # 無いと agetty が login(1) を exec できず、シリアルコンソールから
            # 一切ログインできなくなる (QEMU ブートテストで検出)
            "init", "sudo", "login", "systemd-boot", "initramfs-tools", "zstd",
            "u-boot-menu",  # u-boot-update (extlinux.conf 生成)
            # radxa の keyring / U-Boot は apt 解決しない (dependencies.lock.yaml
            # で固定した deb を customize hook が dpkg で投入する)
            *packages,
        ],
        "customize-hooks": customize_hooks,
        "cleanup-hooks": [
            # mmdebstrap は aptopts を chroot 内の /etc/apt/apt.conf.d/99mmdebstrap
            # にも保存する。Check-Valid-Until 無効化が成果物に残ると、配備後の
            # apt が期限切れ Release を受理してしまうため必ず削除する
            'rm -f "$1/etc/apt/apt.conf.d/99mmdebstrap"',
            # ビルドは snapshot で解決したが、配備後の apt は live リポジトリを
            # 参照させる (security update を受けられるように)。snapshot の URL が
            # 成果物に残ってはいけない (smoke test が検査する)
            f'echo "deb {live_main} {suite} {components}" > "$1/etc/apt/sources.list"',
            f'echo "deb {live_main} {suite}-updates {components}" '
            f'> "$1/etc/apt/sources.list.d/50-{suite}-updates.list"',
            f'echo "deb {live_sec} {suite}-security {components}" '
            f'> "$1/etc/apt/sources.list.d/50-{suite}-security.list"',
            # ビルドホストの DNS 設定 (mmdebstrap が入れる resolv.conf と、
            # systemd-resolved postinst が退避した .bak) を除去し、resolved の
            # stub への symlink に置き換える。単に削除するだけだと初回起動時に
            # glibc が /etc/resolv.conf を見つけられず DNS 解決が壊れる
            # ビルド時に生成された SSH ホスト鍵を削除する。焼き込むと全端末が
            # 同一のサーバー鍵を共有してしまう。初回起動時に trixie 標準の
            # sshd-keygen.service が端末固有の鍵を生成する
            'rm -f "$1/etc/ssh/ssh_host_"*',
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
