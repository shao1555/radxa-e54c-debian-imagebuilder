# 13. rkbin とは何か — Rockchip のファームウェア blob 置き場

[radxa/rkbin](https://github.com/radxa/rkbin) の正体。結論: **「ツール」というより、
Rockchip が配布するクローズドソースのファームウェアバイナリ(blob)の置き場 +
それを加工・合成する補助ツール集**。リポジトリの説明文も "Firmware and Tool Binarys" とそのまま。
radxa/rkbin は Rockchip 公式 [rockchip-linux/rkbin](https://github.com/rockchip-linux/rkbin) 系の
フォークで、U-Boot 世代に合わせたブランチ(`develop-v2026.01` 等)を Radxa が保守している。

## 中身(実測)

### `bin/<SoC 世代>/` — バイナリブロブ本体

`bin/rk35/` の RK3588 関連(E54C = RK3582 は RK3588 の blob を使う):

| ファイル | 役割 |
|---|---|
| `rk3588_ddr_lp4_1866MHz_lp4x_2112MHz_lp5_2400MHz_v1.22.bin` | **DDR 初期化 blob**。DRAM のトレーニング・初期化コード。ソース非公開の代表格。ファイル名が対応メモリ種別と周波数を表す |
| `rk3588_bl31_v1.54.elf` | **BL31 = ARM Trusted Firmware**(EL3 のセキュアモニタ)の Rockchip ビルド。PSCI(CPU 起動/サスペンド)等を担う |
| `rk3588_bl32_v1.20.bin` | BL32 = OP-TEE(セキュア OS)。用途によっては省略可 |
| `rk3588_spl_v1.14.bin` / `rk3588_spl_loader_v1.22.114.bin` | SPL/miniloader(第一段ローダ) |
| `rk3588_usbplug_v1.11.bin` | Maskrom(USB 復旧)モード用 |
| `rk3588_pcie_v3.10.bin` ほか | PCIe EP 等の特殊用途 |

### `RKBOOT/*.ini` / `RKTRUST/*.ini` — 合成レシピ

`boot_merger` にどの blob をどう組み合わせて loader を作るかを指示する設定。
例: `RKBOOT/RK3588MINIALL.ini` は「DDR blob v1.22 + usbplug + SPL → `rk3588_spl_loader_*.bin`」
という合成を定義している(実測)。

### `tools/` — 加工ツール群

- `boot_merger` / `trust_merger`: blob を合成して loader(idbloader 相当)を作る
- `loaderimage` / `resource_tool` / `mkkrnlimg`: Rockchip 独自イメージ形式のパッカー
- `ddrbin_tool.py`: DDR blob のパラメータ(動作周波数、UART ログ出力先/ボーレート等)を
  バイナリのまま書き換えるツール
- `rkdeveloptool` / `rk_sign_tool`: Maskrom 書き込み・署名
- `fit-sign.sh` 等: FIT イメージの署名/検証(セキュアブート用)

## E54C のブートチェーンにおける位置づけ

```
BootROM(SoC 内蔵 ROM)
  → idbloader  = [rkbin の DDR blob] + [U-Boot TPL/SPL]     ← イメージのセクタ 64
  → u-boot.itb = [U-Boot 本体] + [rkbin の BL31] (+ BL32)   ← イメージのセクタ 16384
  → extlinux.conf → Linux カーネル
```

bsp の U-Boot ビルド([05](05-packages-kernel-uboot.md) 参照)は、fork.conf の

```
bsp_radxa-e54c() {
    bsp_rk3588s
    RKBIN_DDR="${BSP_BL31_OVERRIDE}_ddr_lp4_1866MHz_lp4x_2112MHz_lp5_2400MHz"
}
```

のようなファイル名プレフィックス指定で rkbin から blob を選び、U-Boot のビルド成果物と
合成して deb(`u-boot-radxa-e54c`)に詰める。イメージ作成時に `setup.sh update_bootloader` が
これを固定セクタへ書き込む([04](04-image.md))。
u-boot パッケージングリポジトリが rkbin を submodule に持っていたのはこのため
(u-boot-rk2601 = radxa/u-boot `next-dev-v2026.01` + radxa/rkbin `develop-v2026.01`)。

## なぜ blob なのか・何を意味するか

- **DDR 初期化**は DRAM ベンダー固有のトレーニング調整を含み、Rockchip はソースを公開しない
  (業界的にも常態。Intel の FSP、AMD の AGESA に相当する立ち位置)
- **BL31/TF-A** は upstream に RK3588 対応が存在するが、ベンダー製品ラインでは
  Rockchip ビルドのバイナリを使うのが標準構成
- 重要な含意: **カーネルや U-Boot をメインライン化しても、DDR blob と BL31 は rkbin から
  取り続けることになる**(mainline U-Boot の RK3588 ボードも rkbin の DDR blob + BL31 を
  前提にビルドする)。つまり rkbin はベンダーカーネル問題([07](07-vendor-kernel.md)〜)とは
  独立に残る、最後まで消えないベンダー依存
- セキュリティ観点では、この blob 層の脆弱性修正も Rockchip のリリース(rkbin の更新)頼み。
  ただし攻撃面はブート時のみで、ネットワークに露出するカーネルとは性質が異なる
