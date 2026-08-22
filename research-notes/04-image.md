# 04. イメージ組み立て — rootfs.tar から output.img へ

rsdk は `src/share/rsdk/build/image.jsonnet` を jsonnet で評価して **guestfish スクリプト**
(シバン `#!/usr/bin/env -S guestfish -f`)を生成し、`build-image` という名前で保存・実行する。
このスクリプトはリリースアセット `radxa-e54c_bookworm_cli_b2.build-image` としてそのまま公開されている。

guestfish は libguestfs のシェルで、**ループデバイスや root 権限なしに**(QEMU アプライアンス内で)
ディスクイメージの作成・パーティショニング・ファイル操作ができる。CI 上では KVM(なければ TCG)で動く。

## 処理の流れ

E54C は `socs.json` で `soc_family: rockchip` → `partition_table_type: gpt`, `firmware_type: u-boot`。
`efi=true`(デフォルト)、`sdboot=false`、`sector_size=512` での流れ:

1. **10GiB の raw イメージを確保** `disk-create output.img raw 10G`(後で縮小される)
2. **GPT パーティション作成**(単位: 512B セクタ)

   | # | 開始セクタ | 終了 | ラベル | FS | 用途 |
   |---|---|---|---|---|---|
   | 1 | 32768 (16MiB) | 65535 | `config` | vfat | 設定用パーティション(rsetup が利用) |
   | 2 | 65536 (32MiB) | +300MiB | `efi` | vfat | ESP 相当(GPT type = EFI System)。extlinux 起動でもマウントされる |
   | 3 | ESP直後 | 末尾-34 | `rootfs` | ext4 | ルートファイルシステム |

   ※ 先頭 16MiB(セクタ 0–32767)は**意図的に空けてある** — ここに U-Boot が書き込まれる。
   ※ sdboot/EDK2 構成なら ESP は 1024MiB になるが、E54C は u-boot 型なので 300MiB。
   ※ part2/part3 に bootable フラグと GPT type GUID(ESP / Linux filesystem)を設定。

3. **rootfs 展開** `tar-in rootfs.tar / xattrs:true`
4. **ディスク情報の反映**
   - 各パーティションの UUID を `blkid` で取得して `/etc/fstab` を生成
     (`/config` と `/boot/efi` は `x-systemd.automount`)
   - `/boot/extlinux/extlinux.conf` と `/etc/kernel/cmdline` の `root=` を `root=UUID=<rootfs UUID>` に書き換え
5. **rootfs の縮小** `resize2fs -M` でファイルシステムを最小化し、`parted` + `truncate` で
   イメージファイル自体を実サイズまで切り詰め、`sgdisk -ge` でバックアップ GPT を末尾に再配置
   (これにより 10GiB 確保でも配布イメージは実質サイズになる)
6. **U-Boot の書き込み**(firmware_type = u-boot の場合)
   - rootfs 内の `/usr/lib/u-boot/radxa-e54c/setup.sh`(`u-boot-radxa-e54c` パッケージが提供)を取り出し、
     ```bash
     ./setup.sh update_bootloader output.img 512
     ```
     を実行。Rockchip 標準レイアウト(idbloader @ セクタ 64、u-boot.itb @ セクタ 16384)で
     先頭の空き領域に書き込む。SPI フラッシュ用は別パッケージ `u-boot-radxa-e54c-spi`
7. **最終 resize2fs** でファイルシステムをパーティション末尾まで再拡張して終了

## 起動フロー(参考)

```
BootROM → idbloader (DDR init, rkbin blob) → u-boot.itb (U-Boot 2017.09 + BL31)
  → U-Boot distro boot → /boot/extlinux/extlinux.conf (u-boot-menu が生成)
  → kernel 6.1 (linux-image-*-rk2410) + initramfs
  → 初回起動: cloud-initramfs-growroot が rootfs パーティションをディスク全体へ拡張
             rsetup-config-first-boot が初期設定(ユーザー作成等)を実行
```

`systemd-boot` / `efibootmgr` パッケージも入っているが、E54C の既定は U-Boot + extlinux 起動
(`sdboot=false`)。ESP パーティションは将来の systemd-boot 移行や EDK2 構成と共通のレイアウトを保つために存在する。

## 検証方法

配布イメージ・アセットで上記を確認できる:

```bash
# パーティション構成の確認
xz -d radxa-e54c_bookworm_cli_b2.output.img.xz
sgdisk -p radxa-e54c_bookworm_cli_b2.output.img

# 実際に使われた guestfish スクリプトを読む
less radxa-e54c_bookworm_cli_b2.build-image
```
