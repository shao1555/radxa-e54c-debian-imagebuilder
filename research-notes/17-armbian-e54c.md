# 17. Armbian の E54C サポートの実装レベル

armbian/build リポジトリと配布サイトの実測(2026-08-22)。

## 結論

Armbian の E54C 対応は **「Standard support」(メンテナ 2 名付きの正式サポート枠)**で、
実装の中身は**独自開発ほぼゼロ — Radxa と同じベンダー部品(BSP カーネル + ベンダー U-Boot + rkbin)を
Armbian のビルドフレームワークで再統合したもの**。ただしキュレーション(カーネル世代・ユーザーランドの新しさ)は
Radxa 公式イメージより進んでいる。メインラインカーネルのターゲットはまだ無い。

## 構成要素の実測([config/boards/radxa-e54c.conf](https://github.com/armbian/build/blob/main/config/boards/radxa-e54c.conf))

```
BOARDFAMILY="rockchip-rk3588"
KERNEL_TARGET="vendor"                          # vendor のみ。current/edge(メインライン)は無い
BOOTCONFIG="radxa-e54c-rk3588s_defconfig"       # radxa/u-boot にある defconfig をそのまま使用
BOOT_FDT_FILE="rockchip/rk3588s-radxa-e54c.dtb" # ベンダー DTS(rk3588s- 接頭辞)
BOOT_SCENARIO="spl-blobs"                       # rkbin の DDR blob + BL31 を使う構成
```

| 層 | Armbian の実装 | Radxa 公式との差 |
|---|---|---|
| カーネル | `armbian/linux-rockchip` の **`rk-6.1-rkr5.1` ブランチ = 6.1.115** + 独自パッチ(rk35xx-vendor-6.1) | **1 世代新しい**(Radxa 公式は rk2410 = 6.1.84)。ソースは同じ Rockchip BSP 系 |
| DTS | ベンダー DTS `rk3588s-radxa-e54c.dts`(rkr5.1 ブランチに収録済みのものをそのまま) | 同一 |
| U-Boot | `radxa/u-boot` **`next-dev-v2024.10`**(Radxa と同一ソース・同一 defconfig)+ Armbian パッチ | 同一系(ビルドは Armbian が自前で実施) |
| ファームウェア blob | rkbin(spl-blobs シナリオ) | 同一 |
| rootfs | Armbian 独自ビルド。**Debian 13 trixie / Sid / Ubuntu 26.04** まで提供 | **Radxa 公式(bookworm のみ)より大幅に新しい** |
| ボード統合 | LED 設定(netdev トリガーで lan1-3/wan を配線)、DSA マスター `end1` の NetworkManager 除外、netplan の wan インターフェース修正 | Armbian 独自の運用系小物 |

## 配布状況(armbian.com/radxa-e54c)

- サポートレベル: **Standard**、カーネル: vendor 6.1.115
- イメージ: Ubuntu 26.04(GNOME/KDE/minimal)、**Debian 13 trixie minimal**、
  Kali(Sid)、Home Assistant、OpenMediaVault 各種

注目点: **[08-trixie-status.md](08-trixie-status.md) で「技術的には可能」とした
「trixie ユーザーランド + 6.1 ベンダーカーネル」の組み合わせを、Armbian は既に正式出荷している**。
Radxa 公式が bookworm 止まりなのはパッケージング・QA の問題であってカーネル互換性の問題ではない、
という本ドキュメント群の分析の実証例になっている。

## 姉妹機 E52C との比較が示す「次の段階」

Armbian の [radxa-e52c.conf](https://github.com/armbian/build/blob/main/config/boards/radxa-e52c.conf) は既に:

```
KERNEL_TARGET="vendor,current,edge"        # メインラインカーネルも提供
# current/edge 時のオーバーライド:
BOOT_FDT_FILE="rockchip/rk3582-radxa-e52c.dtb"   # メインライン DTS
BOOTCONFIG="radxa-e52c-rk3582_defconfig"
BOOTBRANCH="tag:v2026.07"                        # メインライン U-Boot!
```

つまり E52C は「vendor = ベンダー一式 / current・edge = **メインライン DTS + メインライン U-Boot v2026.07**」の
二本立てに到達済み。E54C も上流 DTS([16](16-upstream-e54c-patch.md) の Chukun Pan パッチ)がマージされれば
同じ形(current/edge ターゲット追加)に進むのがほぼ確実な道筋。
なお mainline U-Boot に `radxa-e52c-rk3582_defconfig` が入っている(v2026.07)ことも
ここから確認できた — E54C の defconfig が続けば、残るベンダー依存は rkbin blob のみになる。

## まとめ: 3 つの選択肢の現在地(E54C)

| | カーネル | U-Boot | ユーザーランド | 特徴 |
|---|---|---|---|---|
| Radxa 公式(rsdk) | vendor 6.1.84(rk2410) | vendor 2017.09 | Debian bookworm | 公式サポート。更新は遅め |
| **Armbian** | vendor **6.1.115**(rkr5.1) | vendor 2017.09(自前ビルド) | **trixie / Ubuntu 26.04** | ベンダー部品 + 新しいユーザーランド + 運用系の磨き込み |
| メインライン(将来) | mainline 7.2+(上流 DTS) | mainline v2026.xx(要 defconfig) | 任意の Debian | rkbin 以外のベンダー依存が消える。E52C は Armbian で到達済み |

## 追記(2026-08-22): Linux 7.2 リリースと Armbian のメインライン追従

- **Linux 7.2 が 2026-08-16 にリリース**され、E54C のスイッチが必要とする rtl8365mb VLAN 対応
  ([16](16-upstream-e54c-patch.md))がリリース版カーネルに入った
- Armbian の rockchip64 系カーネルの階段(v26.11.0-trunk.11 タグ時点の実測):
  **current = 6.18 / edge = 7.1 / bleedingedge = 7.2**。リリースノートでは
  「Rockchip edge を 7.2 へ昇格、カーネルを 7.2-rc7 へバンプ」と 7.2 移行が進行中で、
  姉妹機 E24C は「U-Boot 26.07 + v7.2-rcX に対して再構成済み」と明記
- E54C は現状 vendor ターゲットのみだが、Armbian 側の 7.2 インフラは整っており、
  上流 DTS(7.3 見込み)が入るか、Armbian が patch として先取りすれば
  E52C と同じ `vendor,current,edge` 構成に進める状態
