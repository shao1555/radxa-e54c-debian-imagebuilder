#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""config.yaml + packages.txt + files/ + hooks/ + modules/ から bdebstrap 設定を生成する。

rsdk の rootfs.jsonnet に相当するが、単一ボード・単一エディションなので
jsonnet を使わず素直な Python で組み立てる。

モジュール (Issue #7) の順序契約 (正: docs/modules.md):
  パッケージ導入 (mmdebstrap + 自前 deb)
  → core / module overlay
  → legacy customize hooks (render 内の core 系列 + hooks/customize.d)
  → module rootfs.customize
  → framework boot finalize (update-initramfs → u-boot-update)
  → module rootfs.seal
  → core final seal (machine-id / apt 設定 / sources 書き戻し等の framework invariant)
  → tar 生成
module rootfs.customize は boot finalize より前 (initramfs / extlinux に影響する
変更を反映できる位置)。core final seal は必ずモジュールより後に実行する
(モジュールが core の封印処理後に成果物を書き戻せない順序にするため)。
"""
import argparse
import json
import sys
import yaml
from pathlib import Path

TOP = Path(__file__).resolve().parent.parent

ap = argparse.ArgumentParser()
ap.add_argument("--plan", required=True, help="module-plan.json (resolve 済み)")
ap.add_argument("out_dir")
args = ap.parse_args()
out_dir = Path(args.out_dir).resolve()  # 例: out/rootfs

cfg = yaml.safe_load((TOP / "config.yaml").read_text())

# モジュールは plan だけを参照する (再探索・再解決はしない。plan 記載入力の
# containment / digest 再検証は build-rootfs.sh が直前に verify-inputs で行う)
plan = json.loads(Path(args.plan).read_text())
modules = plan["modules"]
# plan の path は workspace 相対 → 絶対化して bdebstrap.yaml に配線する
for m in modules:
    m["_overlay_dirs"] = [str(TOP / ov["source"]) for ov in m["overlays"]]
    m["_hooks"] = {
        phase: [str(TOP / ref["path"]) for ref in refs]
        for phase, refs in m["hooks"].items()
    }
# requiredSecrets: consumer module の hook 起動行にだけ secret を環境注入する
# (docs/modules.md の限定契約。値は $E54C_SECRET_FILE_<NAME> のファイルから読む)
secrets_by_consumer = {}
for s in plan["requiredSecrets"]:
    secrets_by_consumer.setdefault(s["consumer"], []).append(s["name"])

packages = []
for line in (TOP / "packages.txt").read_text().splitlines():
    line = line.split("#", 1)[0].strip()
    if line:
        packages.append(line)

deb = cfg["debian"]
ub = cfg["uboot"]
# target identity (suite / architecture) は plan を実行時の正とする
# (別 BuildRequest から生成した plan でも、plan の target どおりの rootfs が
#  その artifact digest で記録されるように)
suite = plan["target"]["suite"]
architecture = plan["target"]["architecture"]
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

def module_hook_cmd(m, h):
    """module hook の起動行を生成する。
    secret input は plan の requiredSecrets に従い、consumer module の hook に
    だけ環境注入する (module ID の特別扱いはしない)。値は環境にグローバル
    export されず、build-rootfs.sh が用意する 0600 の一時ファイル (パスのみ
    $E54C_SECRET_FILE_<NAME> で伝わる) から hook 起動時に読む。
    生成 YAML に値もパスも埋め込まれない"""
    prefix = "".join(
        f'{name}="$(cat "$E54C_SECRET_FILE_{name}")" '
        for name in secrets_by_consumer.get(m["id"], [])
    )
    return f'{prefix}"{h}" "$1"'


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
    # core / module overlay をそのまま重ねる (同一フェーズで適用する。
    # 同一パスへの配置は resolve-modules.py が build 前に競合として拒否済み)
    f'if [ -d "{TOP}/files" ]; then cp -a "{TOP}/files/." "$1/"; fi',
    *[f'cp -a "{ov}/." "$1/"' for m in modules for ov in m["_overlay_dirs"]],
    # hostname
    f'echo "{cfg["image"]["hostname"]}" > "$1/etc/hostname"',
    f'echo "127.0.1.1\t{cfg["image"]["hostname"]}" >> "$1/etc/hosts"',
    # legacy フック (chroot 外から $1 を渡して実行。機能はモジュールへ移行済みで
    # 現在は空。未移行機能の受け皿として仕組みは残す)。
    # glob 不一致時に `[ -e ] &&` が偽のままループを抜けると exit 1 になり
    # mmdebstrap がフック失敗と誤認するため、continue で受ける (実際に踏んだ)
    f'for h in "{TOP}"/hooks/customize.d/*.sh; do [ -e "$h" ] || continue; bash "$h" "$1"; done',
    # (デフォルトユーザー作成は modules/default-user、networkd の有効化は
    #  modules/networkd の hook に移行済み。SSH ホスト鍵の初回起動生成は
    #  trixie 標準の sshd-keygen.service に任せる: ConditionFirstBoot=yes。
    #  machine-id を cleanup で消すため初回起動で発動する)
    # ブート用カーネル引数。root= は build-image.sh がイメージ作成時に UUID を注入する。
    # u-boot-update が /etc/kernel/cmdline を参照するよう /etc/default/u-boot を配線して
    # おくことで、実機での以後のカーネル更新でも root= が維持される
    # loglevel=5: auditd 不在時の kernel audit 記録 (NOTICE) 等がシリアル
    # コンソールを洪水にするのを防ぐ (警告/エラーと systemd のブート表示は残る)
    'echo "rw loglevel=5 console=tty1 console=ttyS2,1500000n8" > "$1/etc/kernel/cmdline"',
    'echo \'U_BOOT_PARAMETERS="$(cat /etc/kernel/cmdline)"\' >> "$1/etc/default/u-boot"',
    # module rootfs.customize (legacy hooks の後、framework boot finalize の前)。
    # initramfs / extlinux に影響する変更 (firmware、/etc/initramfs-tools/、
    # cmdline、DT overlay 等) を initramfs 生成前に反映できる位置に置く。
    # 実行ビットは resolver が検証済みで、shebang を尊重して直接実行する
    *[
        module_hook_cmd(m, h)
        for m in modules
        for h in m["_hooks"].get("rootfs.customize", [])
    ],
    # --- framework boot finalize (initramfs → extlinux の順を固定) ---
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

# module rootfs.seal → core final seal の順で cleanup-hooks を構成する。
# core final seal (machine-id / apt 設定 / sources 書き戻し等の framework
# invariant) は必ずモジュールより後 (モジュールが封印後の成果物を書き戻せない)
module_seal_hooks = [
    module_hook_cmd(m, h) for m in modules for h in m["_hooks"].get("rootfs.seal", [])
]

config = {
    "mmdebstrap": {
        "architectures": [architecture],
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
            # (login / sudo は modules/default-user が導入する)
            "init", "systemd-boot", "initramfs-tools", "zstd",
            "u-boot-menu",  # u-boot-update (extlinux.conf 生成)
            # radxa の keyring / U-Boot は apt 解決しない (dependencies.lock.yaml
            # で固定した deb を customize hook が dpkg で投入する)
            *packages,
            # モジュールが宣言するパッケージ (plan の modules[].packages.apt)
            *(p for m in modules for p in m["packages"]["apt"]),
        ],
        "customize-hooks": customize_hooks,
        "cleanup-hooks": [
            *module_seal_hooks,
            # --- ここから core final seal (モジュールより後で実行する) ---
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
            # resolv.conf の安全 invariant: ビルドホスト由来の regular file と
            # .bak の漏洩を拒否する。symlink 判定を優先し (dangling も保持)、
            # モジュール (systemd-resolved の rootfs.seal) が張った symlink は
            # 上書きしない。最終ポリシー (stub symlink) はモジュールが所有する
            '[ -L "$1/etc/resolv.conf" ] || rm -f "$1/etc/resolv.conf"',
            'rm -f "$1/etc/.resolv.conf.systemd-resolved.bak"',
            'rm -rf "$1/var/lib/apt/lists"/*',
            'rm -f "$1/etc/machine-id" "$1/var/lib/dbus/machine-id"',
        ],
    },
}

out_dir.mkdir(parents=True, exist_ok=True)
(out_dir / "bdebstrap.yaml").write_text(yaml.safe_dump(config, sort_keys=False, width=200))
print(f"wrote {out_dir}/bdebstrap.yaml ({len(packages)} extra packages)")
