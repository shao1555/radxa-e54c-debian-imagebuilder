# 15. mainline 版 E54C DTS の作成記録 — ベンダー E52C/E54C 比較と設計判断

> **追記(2026-08-22)**: この作業の 2 日前に公式の E54C 対応パッチ v2 が
> linux-arm-kernel に投稿されていたことが判明。答え合わせと差分検証は
> [16-upstream-e54c-patch.md](16-upstream-e54c-patch.md) を参照。
> 実機投入には上流版を使うこと。

成果物: [assets/rk3582-radxa-e54c-selfmade.dts](assets/rk3582-radxa-e54c-selfmade.dts)
(mainline 命名規約に従い **rk3582**-radxa-e54c.dts として作成。E52C の mainline 収録名
`rk3582-radxa-e52c.dts` に揃えた。上流パッチ発見後([16](16-upstream-e54c-patch.md))は
記録用としてここに退避し、ビルドには上流版 [../kernel/dts/](../kernel/dts/) を使用)

**検証済み**: torvalds/linux master の `rk3588s.dtsi` 依存チェーン(dtsi 4 枚 + dt-bindings ヘッダ 17 枚)を
取得したローカル環境で `gcc -E` + `dtc` によりコンパイル成功(エラー・警告ゼロ、93.6KB の dtb 生成、
phandle/graph endpoint 14 箇所すべて解決)。同環境で mainline の E52C もクリーンにコンパイルできることを
先に確認しており、環境自体の妥当性も担保している。

## 1. ベンダー DTS の E52C vs E54C 比較(差分の要約)

| 項目 | E52C(576 行) | E54C(1080 行) |
|---|---|---|
| ネットワーク | PCIe r8125 ×2(pcie2x1l1/l2) | **GMAC1 (RGMII) + RTL8367RB DSA スイッチ**(wan + lan1-3)|
| M.2 | なし | **pcie2x1l2 = M.2 M-key NVMe**(reset GPIO3_D1)|
| 映像 | なし | **HDMI 出力**(hdmi0 + VOP、CEC)、DP altmode |
| USB | OTG(Type-C 相当)のみ | OTG(**fusb302 USB-C PD**)+ USB2 host ×2 + USB3 host |
| RTC | hym8563 @ i2c5 | hym8563 @ **i2c4**(fusb302 と同バス)|
| LED | power + pwm-leds (lan/wan) | **gpio-leds ×5**(sys/wan/lan1-3)|
| ファン | なし | **pwm-fan @ pwm3**(cooling-levels 0-255)|
| 電源 | 5V 入力(vcc_sysin) | **12V 入力**(dc_12v → vcc5v0_sys)|
| ボタン | ADC Maskrom + GPIO User | GPIO User(GPIO0_B2)|
| PMIC 構成 | rk806-single + rk8602/8603 ×3 | 同一(共通)|

## 2. ベンダー → mainline の翻訳マッピング

| ベンダー記述 | mainline 記述 | 根拠 |
|---|---|---|
| `compatible = "radxa,e54c", "rockchip,rk3588"` | `"radxa,e54c", "rockchip,rk3582", "rockchip,rk3588s"` | E52C mainline の前例 |
| `rk3588-rk806-single.dtsi` include | spi2 配下に rk806 + 全レギュレータをインライン展開 | E52C mainline と同一ブロックを流用(同じ電源ツリー)|
| `usbdrd_dwc3_0`(OTG) | `usb_host0_xhci`(dr_mode=otg, usb-role-switch) | mainline のノード名 |
| `usbhost3_0` / `usbhost_dwc3_0` | `usb_host2_xhci` | 同上 |
| fusb302 の graph(vendor 独自配線) | connector の port@0=orientation / port@1=role / port@2=DP mux | mainline EVB1(rk3588-evb1-v10.dts)の実例に準拠 |
| `hdmi0 { enable-gpios = GPIO4_B6 ACTIVE_HIGH }` | `frl-enable-gpios = GPIO4_B6 ACTIVE_LOW` + `hdmi0_tx_on_h` pinctrl | rock-5a mainline が**同一ピン**で採用している形 |
| `route_hdmi0` / `vp0..3 plane-mask` / `display_subsystem` | `&vp0` の endpoint(`ROCKCHIP_VOP2_EP_HDMI0`)+ `hdmi0-con` コネクタノード | mainline VOP2 の graph 記法 |
| switch `compatible = "realtek,rtl8367rb", "realtek,rtl8365mb"` | `"realtek,rtl8365mb"` のみ(コメントで RTL8367RB-VB と明記) | binding(realtek.yaml)の enum に rtl8367rb が無い |
| switch `reg = <29 0>` | `reg = <29>` | mdio バスの #size-cells=0 |
| switch `dsa,member = <1 0>` | 削除 | 単一スイッチでは不要 |
| gmac1 `snps,reset-gpio`(スイッチと同一 GPIO の二重指定) | 削除(switch 側 `reset-gpios` のみ) | 同一 GPIO の二重要求は mainline では probe 失敗の原因 |
| ports の `local-mac-address = [00 48 54 ...]` | 削除 | プレースホルダ MAC の上流化は不適切(U-Boot が設定)|
| CPU port `label = "cpu"` | 削除 | 現行 DSA binding では不要 |
| `linux,code = <KEY_F15>` | `BTN_0` | 汎用ユーザーボタンの mainline 慣例(E52C と同じ)|
| LED(機能名なし) | `LED_FUNCTION_WAN/LAN` + `function-enumerator` | leds binding の推奨 |
| 12V 入力 `dc_12v` | `vcc_12v_dcin: regulator-12v0` | mainline の命名慣例 |
| vendor 専用ノード群(rknpu/mpp/rkvdec/rga/iep/dmc/rockchip_suspend 等) | 削除 | mainline に存在しない or 自動で有効 |

**維持した実測値**: RGMII 遅延はスイッチ側 `tx/rx-internal-delay-ps = <2000>`、GMAC 側 `tx_delay/rx_delay = <0x0>`、
`clock_in_out = "output"`、fixed-link 1000/full/pause、fusb302 の PDO(sink 5V/1A, source 5V/3A)、
ファンの cooling-levels、全 GPIO 番地。

## 3. ハード検証が必要な項目(実機テスト時のチェックリスト)

1. **HDMI enable の極性**: vendor は ACTIVE_HIGH の enable-gpios、rock-5a mainline は同一ピンを
   ACTIVE_LOW の `frl-enable-gpios` として使う。rock-5a に合わせたが、HDMI が映らなければここを疑う
2. **fusb302 の vbus-supply**: vendor に VBUS スイッチの記述がなく、`vcc_5v0`(常時 5V)を仮置きした。
   実基板に VBUS ゲート GPIO があれば専用 regulator に差し替えるべき
3. **sdmmc/sdhci の電源レール**: vendor は sdmmc vmmc=vcc_3v3_s0。E52C mainline は s3 を使っており、
   回路図なしでは確定できない(どちらも常時 3.3V なので実害は小さい)
4. **スイッチの割り込み**: vendor 同様に未配線(ポーリング動作)。INT ピンが出ていれば追加可能
5. **RTL8367RB-VB の rtl8365mb ドライバ対応**: ドライバは RTL8367RB-VB を対応チップに挙げているが、
   MDIO 接続での実機確認が必要(vendor カーネルも同 binding を使っているため見込みは高い)
6. **HDMI 音声・DP altmode**: 音声は mainline の HDMI QP ドライバ側の対応に依存(6.15+)。
   DP altmode graph は EVB1 同様に配線済みだが表示は mainline の進捗次第

## 4. ビルド・利用方法

カーネルツリーに組み込む場合:

```bash
cp kernel/dts/rk3582-radxa-e54c.dts <kernel>/arch/arm64/boot/dts/rockchip/
# Makefile に追加:
#   dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3582-radxa-e54c.dtb
make ARCH=arm64 dtbs
```

スタンドアロン検証(本ドキュメントで実施した方法):

```bash
gcc -E -nostdinc -I <kernel>/include -I <kernel>/arch/arm64/boot/dts/rockchip \
    -undef -D__DTS__ -x assembler-with-cpp -o e54c.pre.dts rk3582-radxa-e54c.dts
dtc -I dts -O dtb -o rk3582-radxa-e54c.dtb e54c.pre.dts
```

実機で試す場合(trixie 6.12+ カーネル or bsp .stable プロファイル):
dtb を `/boot` 配下に置き、extlinux.conf の `fdt` を差し替える(U-Boot・rkbin はベンダー deb のまま)。
主要機能(GMAC+DSA、PCIe、USB、ファン)は 6.12 で足りる。HDMI は 6.13+、フル機能は 6.15+ を推奨。

## 5. upstream 投稿する場合の残作業

1. `Documentation/devicetree/bindings/arm/rockchip.yaml` に `radxa,e54c` を追加する dt-bindings パッチ
2. `arch/arm64/boot/dts/rockchip/Makefile` へのエントリ追加
3. 実機での動作確認結果をコミットメッセージに記載(E52C の前例があるためレビューは通しやすい)
4. `make dtbs_check` での binding 検証
