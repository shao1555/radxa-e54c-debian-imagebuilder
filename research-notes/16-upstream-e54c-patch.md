# 16. 上流に投稿された E54C DTS パッチとの差分検証(答え合わせ)

[15](15-e54c-mainline-dts.md) で自作した DTS の 2 日後(投稿日 2026-08-20)に、
**Chukun Pan 氏による公式の E54C 対応パッチ v2** が linux-arm-kernel に投稿されていた。

- [PATCH v2 0/2 カバーレター](http://lists.infradead.org/pipermail/linux-arm-kernel/2026-August/1163430.html)
- [PATCH v2 1/2 dt-bindings](http://lists.infradead.org/pipermail/linux-arm-kernel/2026-August/1163432.html)(**Rob Herring の Acked-by 済み**)
- [PATCH v2 2/2 DTS 本体](http://lists.infradead.org/pipermail/linux-arm-kernel/2026-August/1163431.html)(1,184 行)

パッチから復元した DTS は [../kernel/dts/rk3582-radxa-e54c.dts](../kernel/dts/rk3582-radxa-e54c.dts)
として imagebuilder に収録し(7.3 で上流化されたら自動で不使用になる方式)、
ローカル検証環境でコンパイル成功も確認済み(95.4KB dtb、警告ゼロ)。
作者は実機でテスト済み(SD ブート、USB 群、スイッチ、HDMI 1080p、NVMe、ボタン/LED)で、
**回路図([radxa_e54c_v1.2_schematic.pdf](https://dl.radxa.com/e/e54c/hw/radxa_e54c_v1.2_schematic.pdf))を参照して作られている**。

## 答え合わせ: 一致した点(自作版の設計判断が正しかった箇所)

| 項目 | 判定 |
|---|---|
| ファイル名 `rk3582-radxa-e54c.dts` / compatible 3 連 | ✅ 完全一致 |
| include 一式・aliases(ethernet0/mmc0/mmc1)・chosen | ✅ 完全一致 |
| **HDMI: `frl-enable-gpios = GPIO4_B6 ACTIVE_LOW` + 5 pinctrl groups + `hdmi0_tx_on_h`** | ✅ 完全一致(懸念だった極性は rock-5a 踏襲で正解) |
| スイッチ compatible を `realtek,rtl8365mb` 単独に落とす | ✅ 一致 |
| reset-gpios(GPIO3_B7)を switch 側のみに置く(gmac との二重指定排除) | ✅ 一致 |
| CPU ポート port@6 rgmii + tx/rx-internal-delay-ps 2000 | ✅ 一致 |
| プレースホルダ MAC の削除 | ✅ 一致(上流はさらに nvmem 化) |
| pcie2x1l2(pinctrl 名 / reset GPIO3_D1) | ✅ 一致(供給レール名のみ相違) |
| rk806 + rk8602/8603 電源ブロック、8 コア cpu-supply、RK3582 コメント | ✅ ほぼ同一(E52C 由来で共通) |
| USB-C graph 構造(EVB1 型 3 ポート + usbdp mode/orientation-switch + sbu GPIO1_A6/GPIO3_D5) | ✅ 構造一致 |
| LED/ボタン/RTC/fusb302 の GPIO 番地すべて | ✅ 一致 |
| User ボタンを BTN_0 に | ✅ 一致 |

## 上流版が優る点(回路図・実機なしでは到達できなかった差分)

### 回路図由来(自作版の誤り・欠落)

1. **eMMC(sdhci)は `status = "disabled"`** — E54C は eMMC 非搭載(オプション)で、
   **SPI Flash とピン排他**。自作版は okay にしており、これが最大の実害バグだった
2. **`&sfc` で 16MB SPI NOR を有効化**(jedec,spi-nor @ fspim0)— vendor DTS にも存在せず、
   回路図からしか分からない
3. **EEPROM(bl24c16)を nvmem fixed-layout 化**し、オフセット 0x9e〜 の工場書込 MAC
   (eth_mac0..3)を DSA 各ポートに `nvmem-cells` で供給
4. **Type-C VBUS の実体は GPIO3_C0** ゲートの `vbus_typec0`(自作版は vcc_5v0 仮置きだった。
   懸念点リスト #2 の答え)。給電ツリーも `typec_vin → vcc_sysin`(USB-C 給電対応)まで模型化
5. **RTL8367 の電源は 5V ではなく 3.3V(AVDDH)**、startup-delay 10ms、
   さらに gmac1 の `phy-supply` として接続(vendor DTS の 5V 記述は不正確だった)
6. スイッチの**割り込み線(GPIO3_B6)を interrupt-controller として配線**、PHY0-4 に割当
   (phy4 の存在も回路図由来)
7. sdmmc の vmmc は **vcc_3v3_s3**(懸念点 #3 は E52C mainline 側が正解。自作版は vendor 追従で s0)

### 実機テスト由来(v2 での修正点を含む)

8. gmac1 は **`phy-mode = "rgmii-id"`** + **`/delete-property/ snps,tso`**(TSO 無効化)+
   fixed-link から `pause` 削除 — v2 の changelog「Update phy-mode for switch」に対応する調整
9. ADC Maskrom ボタン追加(keyup-threshold **1800000**。E52C の 18000 は誤りで v2 で修正された)
10. **NPU 有効化**(rknn_core_0..2 + `&pd_npu` domain-supply)— RK3582 でも NPU が使える
11. **HDMI 音声**(`&hdmi0_sound` + `&i2s5_8ch`)
12. **ファン/thermal なし** — 自作版は vendor DTS の pwm-fan を移植したが、上流は入れていない
    (テスト済みリストにもファンなし。ファンレス設計 or ヘッダ未実装の可能性)
13. usb_host0_ohci を有効化していない(自作版は有効化)。dr_mode 指定も省略(既定が otg)

## 重要な新事実: スイッチは v7.2 のコミットに依存

カバーレターより: スイッチの動作に
[`9da2c8672f77` "net: dsa: realtek: rtl8365mb: add VLAN support"](https://github.com/torvalds/linux/commit/9da2c8672f77)
(**Linux v7.2**)が必要。つまり **trixie の 6.12 カーネルにこの DTS を持ち込んでも、
この VLAN 対応をバックポートしない限りスイッチは正しく動かない**。
[14](14-mainline-rk3588.md) の「6.12 で全部揃う」という評価は、この 1 点だけ訂正が必要
(GMAC 単体・PCIe・USB は 6.12 で足りるが、DSA スイッチのフル機能は 7.2+)。

## 結論

- 自作版は骨格・主要配線(HDMI 極性含む)でほぼ正解だったが、
  **回路図と実機がないと埋まらない差分**(eMMC/SPI 排他、MAC の nvmem、VBUS GPIO、
  rgmii-id/TSO 調整)で上流版が明確に優る
- **今後は上流 v2 を正とする**。bindings は Acked 済みで、マージは時間の問題
  (入れば [14](14-mainline-rk3588.md) で述べた「Debian 標準カーネルで E54C が動く」状態が公式に実現)
- 自作版 [assets/rk3582-radxa-e54c-selfmade.dts](assets/rk3582-radxa-e54c-selfmade.dts) は
  検証記録として残すが、実機に投入するなら upstream-v2 の方([../kernel/dts/](../kernel/dts/) 収録)を使うこと
- 実機投入時の要件: カーネル 7.2+(または 6.x + `9da2c8672f77` のバックポート)

## 追記(2026-08-22): Linux 7.2 リリースで依存条件が解消

- **Linux 7.2 は 2026-08-16 にリリース済み**([kernelnewbies](https://kernelnewbies.org/Linux_7.2))。
  スイッチの依存コミット(rtl8365mb VLAN 対応)は**リリース版カーネルに入った**ため、
  バックポート不要で「7.2 + 本パッチの DTS」の構成が組める
- 本パッチ(v2、2026-08-20 投稿)は 7.2 リリース後の投稿なので、マージ先は **7.3 の
  マージウィンドウ**(7.2 リリース直後に開放。7.3 final は例年ペースなら 2026 年 10〜11 月頃)
- つまり E54C のメインライン対応の現実的な時間軸: **7.3(2026 年秋)で DTS 収録 →
  以降のディストロカーネルで「DTS 同梱で動く」状態に**
