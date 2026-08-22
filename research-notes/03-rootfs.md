# 03. rootfs 生成 — Debian ソースからの組み立て方

rsdk の `rsdk-build` スクリプト(`src/libexec/rsdk/rsdk-build`)が
`src/share/rsdk/build/rootfs.jsonnet` を jsonnet で評価して **bdebstrap 用の設定 JSON** を生成し、

```bash
sudo bdebstrap -c rootfs.json --name <出力ディレクトリ> --force
```

を実行する。bdebstrap は Debian 公式ツール **mmdebstrap** の YAML/JSON フロントエンドで、
実体は mmdebstrap による普通の Debian bootstrap である。

以下は b2 リリースの `radxa-e54c_bookworm_cli_b2.config.yaml`(実際に使われた設定)と
rsdk ソースの両方で確認した内容。

## 1. ベースは素の Debian bookworm

- **ミラー**: `https://deb.debian.org/debian`(公式プライマリアーカイブ)
- **suite**: `bookworm` / **architecture**: `arm64` / **variant**: `apt`(essential + apt の最小構成から開始)
- **components**: `main contrib non-free non-free-firmware`
- setup-hook で以下の APT ソースを追加:
  - `50-bookworm.list`(main)
  - `50-bookworm-updates.list`
  - `50-bookworm-backports.list`
  - `50-bookworm-security.list`(security.debian.org 相当)

つまり Debian 本体のパッケージは**一切改変されず、公式アーカイブのバイナリをそのまま**使っている。

## 2. Radxa の APT リポジトリを追加

setup-hook で 2 つの独自リポジトリを追加(詳細は [05-packages-kernel-uboot.md](05-packages-kernel-uboot.md)):

```
# SoC 別リポジトリ(E54C の SoC rk3582 は soc_specific_repo 扱い)
deb https://radxa-repo.github.io/rk3582-bookworm rk3582-bookworm main   # 80-radxa-rk3582.list

# 共通リポジトリ
deb https://radxa-repo.github.io/bookworm bookworm main                 # 70-radxa.list
```

- 鍵は `radxa-archive-keyring` パッケージ(customize-hook で `signed-by` を付与)。
- 各リポジトリの `pkgs.json`(パッケージバージョンのスナップショット)を `/etc/rsdk/` にダウンロードして記録。
- test channel ビルドでは suffix `-test` が付き `bookworm-test` / `rk3582-bookworm-test` を使う。

このほか、ローカル deb を差し込むための `local-apt-repository`(`/srv/local-apt-repository`、
Pin-Priority 1999)も一時的に設定される(公式ビルドでは空。ビルド後にソースリスト削除)。

## 3. インストールされるパッケージ

### essential-hooks 段階(カーネル・ブートローダー)

`rsdk/src/share/rsdk/build/mod/packages/categories/core.libjsonnet` が生成する
フックで、product 名から規約的に決まるメタパッケージをインストールする:

```bash
apt-get install -y rsetup radxa-bootutils python-is-python3 initramfs-tools
apt-get install -y u-boot-radxa-e54c linux-headers-radxa-e54c   # firmware type = u-boot
apt-get install -y linux-image-radxa-e54c
apt-get install -y --install-recommends -oDpkg::Options::=--force-confnew task-radxa-e54c
apt-get full-upgrade -y --allow-downgrades
```

- `linux-image-radxa-e54c` → 実体 `linux-image-6.1.84-*-rk2410`(Rockchip ベンダーカーネル 6.1)
- `u-boot-radxa-e54c` → 実体 `u-boot-rk2410`(Rockchip 2017.09 系 U-Boot)
- `task-radxa-e54c` → `radxa-profiles` ソース由来のボード設定メタパッケージ
  (`radxa-system-config`, カーネル cmdline 設定などを引き込む)
- E54C(rk3582 は rockchip / bookworm)では `--install-recommends` が有効

### packages リスト(cli エディション)

cli エディションは `core + base` パッケージセット。b2 の実リスト(config.yaml より):

- **コア**: `init`, `sudo`, `ssh`, `systemd-timesyncd`, `cloud-initramfs-growroot`(初回起動時のパーティション拡張),
  `network-manager`, `wpasupplicant`, `bluetooth`, `iw`, `efibootmgr`, `systemd-boot`
- **ファームウェア**: `firmware-linux`, `firmware-iwlwifi`, `firmware-brcm80211`, `firmware-realtek`(Debian non-free-firmware)
- **Radxa 系**: `radxa-archive-keyring`, `radxa-firmware`, `radxa-udev`, `radxa-otgutils`,
  `rsetup-config-first-boot`(初回起動セットアップ), `libreelec-alsa-utils`
- **ユーティリティ**: `htop`, `vim`, `nano`, `tmux`, `curl`, `wget`, `i2c-tools`, `gpiod`, `spi-tools`,
  `mtd-utils`, `pciutils`, `usbutils`, `samba`, `avahi-daemon`, `alsa-utils`, `pipewire-audio`,
  `libmraa2` ほか(全リストは config.yaml / manifest 参照)

デスクトップ版(kde/xfce/gnome など)のエディション定義も rsdk にはあるが、
E54C は `products.json` 上 `cli` のみサポート。

## 4. customize-hooks(仕上げ)

1. `apt-get full-upgrade --allow-downgrades` → `autoremove --purge`
2. Radxa リポジトリの sources.list に `signed-by` を付与、local-apt-repository の後始末
3. `update-alternatives --set regulatory.db /lib/firmware/regulatory.db-upstream`(Debian では upstream 版 regdb を使用)
4. `/etc/hosts` に `127.0.1.1 radxa-e54c` 追記(hostname は `radxa-e54c`)
5. ビルド設定を rootfs 内へ記録:
   - `/etc/rsdk/config.yaml`(この config.yaml 自身)
   - `/etc/radxa_image_fingerprint`(FINGERPRINT_VERSION=2、ビルド日時、rsdk リビジョン)
6. `update-initramfs -c -k all` と **`u-boot-update`**(u-boot-menu パッケージ)を chroot 内で実行
   → `/boot/extlinux/extlinux.conf` を生成(U-Boot の distro boot 用)
7. `/boot/efi` の tmpfs マウントを外して実ディレクトリ化(EFI パーティションの中身をここに保持)
8. `seed.tar.xz` を出力(fingerprint と /etc/rsdk の控え)

## 5. cleanup-hooks

ビルド環境固有の情報を削除して確定:

```
rm -rf $1/etc/resolv.conf
rm -rf $1/var/lib/apt/lists/*
rm -rf $1/etc/machine-id $1/var/lib/dbus/machine-id
rm -rf $1/var/log/journal/*
```

出力は `rootfs.tar`(+ bdebstrap が `manifest` と `config.yaml` を自動保存)。

## b2 の主要パッケージ実測バージョン(manifest より)

| パッケージ | バージョン |
|---|---|
| linux-image-radxa-e54c | 6.1.84-5(実体: linux-image-6.1.84-5-rk2410) |
| u-boot-radxa-e54c | 2017.09-44-6b5f314 |
| u-boot-rk2410 | 2017.09-44-3ba926a |
| task-radxa-e54c | 0.4.28(radxa-profiles) |
| radxa-firmware | 0.2.22 |
| rsetup / rsetup-config-first-boot | 0.4.13 |
| u-boot-menu | 4.2.2 |
