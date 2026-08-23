# 19. kernel config 比較: Debian ベース化 (Issue #2) の調査

base_config を defconfig から debian (linux-config パッケージの arm64 config) に
切り替えた場合、Radxa 公式イメージ / Rockchip kernel SDK の config と比べて
E54C のハードウェアサポートに不足が出ないかを調査した。

## 比較対象

| 系統 | 実体 |
|---|---|
| 現行 (defconfig ベース) | mainline 7.2 の `defconfig` + `kernel/config/e54c.config` の最終 .config (実ビルド品) |
| Debian ベース候補 | devcontainer の `linux-config-6.12` パッケージ `config.arm64_none_arm64` |
| Radxa 公式イメージ | radxa/kernel `linux-6.1-stan-rkr4.1` の `rockchip_linux_defconfig` + `rk3588_linux.config` + radxa-repo/bsp `linux/rk2410/kconfig.conf` (E54C は rk2410 プロファイル。fork.conf の SUPPORTED_BOARDS に radxa-e54c を確認) |
| Rockchip SDK | rockchip-linux/kernel `develop-6.1` の `rockchip_linux_defconfig` (radxa 版はこのフォークで、radxa 版が上位互換) |

規模感: 現行 =y 3295 / =m 1531 に対し、Debian は =y 3064 / =m 4162。
Debian ベースはモジュール数が約 2.7 倍になる (≒ ビルド時間の主因)。

## 方法

vendor 側で有効 (=y/=m) な全オプションについて、
(1) mainline 7.2 に symbol が存在するか (7.2 ソース全 Kconfig から抽出した
21,430 symbol と照合)、(2) Debian config での状態、(3) 現行 .config での状態
を機械的に突き合わせた。vendor 独自 symbol (mainline に無いもの。例:
CRYPTO_DEV_ROCKCHIP2、ROCKCHIP_SUSPEND_MODE、MALI_CSF_SUPPORT) は
ベース選択と無関係なので除外した。

## 結果 1: vendor 有効 & mainline 7.2 に存在 & Debian で無効 = 102 件

精査すると、E54C (ヘッドレスのルーター/サーバー用途) に実害があるのは
**1 グループだけ**だった:

| オプション | vendor | Debian | 現行 | 影響 |
|---|---|---|---|---|
| NET_DSA_REALTEK / _RTL8365MB / _SMI / _MDIO / NET_DSA_TAG_RTL8_4 | m | **明示 n** | m/y | **スイッチ (lan1-4) 全滅**。ただし既存 fragment が上書きするので実害なし |

残り約 95 件は以下のいずれかで、E54C に不要:

- カメラセンサー: VIDEO_IMX214/IMX219/IMX415/OV4689/OV5647/OV7251、VIDEO_ROCKCHIP_CIF
- オーディオ: SND_SOC_ES8311/ES8323/RT5651、SND_SOC_ROCKCHIP_*
- ディスプレイ: ROCKCHIP_RGB/LVDS/INNO_HDMI/DW_DP、PHY_ROCKCHIP_SAMSUNG_DCPHY (MIPI)、DRM_PANEL_*
- デバッグ/開発: DEBUG_SPINLOCK、LKDTM、MMC_TEST、REGULATOR_DEBUG、MAC80211_DEBUGFS、WERROR 等
- ポリシー既定値の違い (機能欠落ではない): CPU governor 既定、THERMAL 既定 governor、
  PCIEASPM_POWERSAVE、UCLAMP、WQ_POWER_EFFICIENT_DEFAULT、CC_OPTIMIZE_FOR_SIZE
- E54C に無いハードウェア: SCSI_UFS_*、CHARGER_BQ24735、MOUSE_CYAPA、LEDS_IS31FL32XX 等

## 結果 2: E54C DTS の compatible 16 種は Debian config で全カバー

| compatible | ドライバ CONFIG | Debian |
|---|---|---|
| realtek,rtl8365mb | NET_DSA_REALTEK_RTL8365MB | n → **fragment で担保 (唯一の例外)** |
| rockchip,rk806 (SPI) | MFD_RK8XX_SPI | y |
| rk806 レギュレータ | REGULATOR_RK808 | m |
| rockchip,rk8602/rk8603 (CPU VDD) | REGULATOR_FAN53555 (mainline は fan53555.c が rk860x を吸収) | m |
| haoyu,hym8563 (RTC) | RTC_DRV_HYM8563 | m |
| fcs,fusb302 (USB-C) | TYPEC_FUSB302 | m |
| belling,bl24c16a (EEPROM) | EEPROM_AT24 | m |
| jedec,spi-nor | MTD_SPI_NOR | m |
| adc-keys / gpio-keys / gpio-leds | KEYBOARD_ADC / KEYBOARD_GPIO / LEDS_GPIO | m |
| fixed-layout (nvmem) | nvmem コアに組込 | - |

ブート必須の SoC 基盤 (PINCTRL_ROCKCHIP、COMMON_CLK_ROCKCHIP、CLK_RK3588、
ROCKCHIP_GRF、ROCKCHIP_PM_DOMAINS、ARM_SCMI_PROTOCOL) は Debian でも =y。
ストレージ (MMC_DW_ROCKCHIP、MMC_SDHCI_OF_DWCMSHC、BLK_DEV_NVME)、
USB (DWC3)、ネット (STMMAC/DWMAC_ROCKCHIP) は =m だが、initramfs 経由の
ブートなので問題ない (現に Debian 公式カーネルは RK3588 ボードで起動実績がある)。

逆に Debian ベースで**増える**カバレッジもある: MOTORCOMM_PHY (=m。defconfig
ベースの現行は n)、ROCKCHIP_MBOX (=y。現行 n)、CRYPTO_DEV_ROCKCHIP (=m)、
USB ドングル/センサー類の広範な =m 群。

## 結果 3: 既存 fragment はほぼそのまま有効 (緩和 1 件 + 追加 2 件)

merge_config は fragment を最後に重ねるので、Debian ベースでも
`kernel/config/e54c.config` の全行がそのまま強制される。特に:

- NET_DSA_REALTEK 系 → Debian の明示 n を上書き (これが無いと起動してもスイッチが死ぬ)
- DEBUG_INFO_NONE=y → Debian の debug info (BTF 等) を落とし、ビルド時間と
  成果物サイズの爆発を一部抑制
- LSM="landlock,lockdown,yama,integrity,apparmor" → Debian の長い LSM 列を
  決定的な値に上書き (AppArmor は QEMU ブートテストが実測で検証)

実際の切替では以下の調整が必要だった:

- **MMC_SDHCI_OF_DWCMSHC を y→m に緩和**: debian ベースでは依存
  MMC_SDHCI_PLTFM=m のため y に昇格できない (ビルド時の fragment 反映検証が
  fail-fast で検出)。initramfs でロードされるので m で十分
- **MMC_DW / MMC_DW_ROCKCHIP=m を追加** (Codex レビュー指摘): E54C の実ブート
  パスは microSD = sdmmc ノード (dw_mmc) で、eMMC 側 (sdhci/DWCMSHC) は SFC と
  競合するため DTS で disabled。本命の dw_mmc が fragment で担保されていなかった

## 残リスクと結論

- linux-config-6.12 を 7.2 に olddefconfig で当てるため、6.12 以降に追加された
  新規オプションは Kconfig 既定値になる (多くは n)。fragment 検証が担保するのは
  列挙分のみ
- **QEMU ブートテストの限界**: ディスクは virtio、NIC は virtio-net のため、
  実 SD コントローラ (dw_mmc)・DSA スイッチ (rtl8365mb)・dwmac は実動検証
  されない。これらは smoke test の静的検査 (モジュール実在) + 実機確認が担保
- seed (linux-config パッケージ) は devcontainer の日次再構築で更新されるため、
  CI のカーネルキャッシュキーに seed バージョンを含める (更新の取りこぼしと
  再現性のブレを防ぐ)
- ビルド時間: モジュール数 ~2.7 倍で devcontainer 実測 63 分 (defconfig 比 ~3 倍)。
  CI は ccache + キャッシュで吸収し、config.yaml は kernel セクションのみを
  キーにハッシュする (無関係な変更で 63 分の再ビルドを防ぐ)

**結論: ハードウェアサポートの面で Debian ベース化に不足は無い。**
唯一の実ギャップ (NET_DSA_REALTEK) は既存 fragment が既に埋めている。
トレードオフはビルド時間のみ。切替は config.yaml の base_config 変更に加えて
上記の fragment 調整 (緩和 1 件 + microSD ドライバの明示 2 件) と、
モジュール圧縮 (.ko.xz)・CI キャッシュキーへの対応を伴った。切替後は実機での
スイッチ疎通確認 (lan1-4、VLAN) と microSD ブートを最初のマイルストーンに
するのがよい。
