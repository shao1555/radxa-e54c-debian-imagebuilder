# 14. メインラインカーネルで RK3588/E54C は「DTS を当てるだけ」で済むのか

Collabora のステータス文書
([mainline-status.md](https://gitlab.collabora.com/hardware-enablement/rockchip-3588/notes-for-rockchip-3588/-/blob/main/mainline-status.md)、
調査時点で 22 時間前更新)と、mainline ツリー・ベンダー DTS の実測に基づく評価。2026-08-22 時点。

## 結論

**SoC の IP ブロック対応はほぼ完了しており、「新しいボードの追加 ≒ メインライン式 DTS を書くこと」
という段階に本当に到達している。ただし「済む」には 3 つの条件が付く**(後述)。

## Collabora ステータスの要点(E54C 関連を抜粋)

SoC 列 = ドライバがメインラインに入った最初のバージョン:

| 機能 | メインライン対応 | E54C(ルーター用途)への影響 |
|---|---|---|
| Ethernet (GMAC) | **6.1〜6.3** | 必須 ✓ |
| PCIe2 | **6.6〜6.7** | 必須(M.2 NVMe)✓ |
| USB2 / USB3 | **6.5〜6.10** | 必須 ✓ |
| cpufreq | **6.11** | 重要 ✓ |
| Thermal ADC | **6.4〜6.11** | 重要 ✓ |
| eMMC / SD | **6.0〜6.5** | 必須 ✓ |
| SATA | 6.5 | ✓ |
| GPU (panthor) | 6.10 | ヘッドレスなので無関係 |
| HDMI 出力 | 6.13〜(4K60 は投稿中) | 無関係 |
| NPU (rocket) | 6.18 | 無関係 |
| 動画デコード (VDPU381 H.264/265) | 7.0 | 無関係 |
| 動画エンコード | WIP | 無関係 |
| **DMC(メモリ周波数スケーリング)** | **TODO(未対応)** | アイドル消費電力が vendor カーネルより高くなる可能性 |
| HW crypto engine | 投稿中(未マージ) | IPsec 等で性能差の可能性(CPU 暗号で代替可) |

**ルーター用途に必要な機能は 6.12 までに全部揃っている**。つまり Debian trixie の標準カーネル
(6.12)でも、DTS さえあれば E54C のコア機能は動く計算になる。
(なお表中の 7.x はメインラインのバージョン番号が 6.19 の次に 7.0 になったことによる)

## RK3582 の前例: E52C は既にメインライン入りしている

- `arch/arm64/boot/dts/rockchip/rk3582-radxa-e52c.dts` が **torvalds/linux master に収録済み**
  (734 行。2024-12 に v3 投稿 → マージ)
- compatible = `"radxa,e52c", "rockchip,rk3582", "rockchip,rk3588s"` として
  `rk3588s.dtsi` を include する構成。**RK3582(RK3588S の選別品)の扱いの前例が upstream にある**
- E54C の DTS はまだメインラインに無い(radxa 系で収録済みは E52C, E20C, E25, ROCK 5 系など)

## E54C 固有のハードルは低い(実測)

ベンダー DTS(1080 行)を解析した結果、E54C の 4 ポート GbE は:

```
GMAC1 (RGMII, dwmac-rk ドライバ) ← mainline 6.1〜対応済み
  └─ Realtek RTL8367RB スイッチ(DSA)
       compatible = "realtek,rtl8367rb", "realtek,rtl8365mb"  ← mainline の DSA binding そのもの
```

ベンダーカーネルの E54C DTS が**既にメインライン系の Realtek DSA ドライバ
(rtl8365mb、RTL8367RB-VB 対応)の binding を使っている**。つまりネットワーク経路は
メインラインドライバで成立することがベンダー構成自体によって示されている。
E54C のメインライン DTS は「E52C をテンプレに、スイッチノード等を足す」程度の差分で書ける。

## 「DTS を当てるだけ」に付く 3 つの条件

1. **DTS は「書く」であって「流用」ではない**
   ベンダー DTS はベンダーカーネルの binding(rockchip_vop / sensor-dev 等)前提なので
   コピーでは動かない。メインライン式に書き起こす必要がある。ただし E52C という
   90% 流用可能なテンプレが upstream にあるため、実工数は小さい(数日〜2 週間 + 実機検証)
2. **ブート層は別途必要(そして既存流用で足りる)**
   rkbin の DDR blob / BL31([13](13-rkbin.md))は残る。mainline U-Boot に
   e52c/e54c の defconfig はまだ無い(rock5b 等はある)が、
   **Radxa のベンダー U-Boot は extlinux 経由でメインラインカーネルをそのまま起動できる**ため、
   「U-Boot はベンダーのまま、カーネルだけメインライン」の構成が現実的
3. **SoC 側の未対応項目を許容すること**
   DMC 未対応(アイドル電力増の可能性)、crypto engine 未マージ、動画エンコード WIP など。
   ヘッドレスルーターでは実害が小さいものばかり

## E54C にとっての現実的なパス

```
Step 1: E52C の mainline DTS をベースに rk3588s-radxa-e54c.dts(mainline 式)を作成
        + RTL8367RB の DSA ノード追加(ベンダー DTS の binding がほぼそのまま参考になる)
Step 2: bsp の .stable-6.12 / .mainline プロファイル([12](12-bsp-stable-profiles.md))か
        Debian trixie カーネル + 自前 DTB で実機検証
        (U-Boot・rkbin はベンダー deb のまま)
Step 3: 動いたら upstream に DTS を投稿(E52C の前例があるためレビューは通しやすい)
        → 入れば Debian 標準カーネルだけで E54C が動く状態になり、
          ベンダーカーネル問題([07](07-vendor-kernel.md)〜[10](10-lts-lifecycle.md))が根本解決
```

## まとめ

- 「RK3588 をメインラインで使うなら DTS を当てるくらいで済むか」→ **2026 年時点では概ね Yes**。
  Collabora らの上流化により、ボード追加の作業は本当に DTS(+実機検証)に集約されつつある
- E54C は (a) 同一 SoC の E52C が既にメインライン入り、(b) 固有ハードが DSA スイッチ 1 個、
  (c) ヘッドレスで未対応領域(表示・映像・NPU)と無縁 — と、メインライン移行の条件が
  例外的に良いボード
- 残るベンダー依存はブート層の rkbin blob のみで、これはメインライン化後も消えない
