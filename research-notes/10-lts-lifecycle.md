# 10. Rockchip 本家の stable 追従と LTS 短命化の影響

[09-security-updates.md](09-security-updates.md) の続き。
「Rockchip 本家 BSP は 6.1.141 / 6.6.89 まで追従している」という観察と、
「最近の LTS はサポート期間が短い」という 2 点を実測で整理する(2026-08-22 時点)。

## バックポートのボトルネックは Rockchip 本体ではなく「下流の段」

実測した各段のカーネルバージョン:

```
upstream 6.1.y stable            : 継続更新中(EOL 2027-12)
  │
  ▼ Rockchip が継続的にマージ
rockchip-linux/kernel develop-6.1: 6.1.141   ← 本家開発ブランチはよく追従している
rockchip-linux/kernel develop-6.6: 6.6.89
  │
  ▼ SDK リリース時にスナップショット化(rkr = Rockchip Release)
radxa/kernel linux-6.1-stan-rkr4.1: 6.1.84   (rk2410 世代の元)
radxa/kernel linux-6.1-stan-rkr5  : 6.1.99
radxa/kernel linux-6.1-stan-rkr5.1: 6.1.115  (rk2501 世代の元)
  │
  ▼ Radxa が世代パッケージ化
radxa-pkg/linux-rk2410 (6.1.84)  : E54C を含む rk3588/rk3582 系ボードが使用中
radxa-pkg/linux-rk2501 (6.1.115) : 存在するが対象は rock-pi-4 (rk3399) /
                                   rock-pi-s (rk3308) 等の旧ボードの載せ替え用
                                   (debian/control 実測。E54C は含まれない)
  │
  ▼ ボード別メタパッケージ
linux-image-radxa-e54c = 6.1.84-8 のまま
```

つまり「ベンダーがバックポートしない」というより、**upstream → Rockchip 開発ブランチまでは
流れているが、「SDK スナップショット切り出し → ボードメーカーの世代更新 → 個々のボードへの適用」
の各段で数ヶ月〜年単位の遅延が積み重なる**構造。E54C の 6.1.84 と本家 develop-6.1 の 6.1.141 の
差(約 57 リリース分の stable 修正)は、この中間段に滞留している分。

## LTS 短命化の現状(kernel.org 実測)

| 系列 | リリース | EOL 予定 | 期間 |
|---|---|---|---|
| 5.10 | 2020-12 | 2026-12 | 6 年(6 年 LTS 時代の最後) |
| 5.15 | 2021-10 | 2026-12 | 約 5 年 |
| 6.1 | 2022-12 | **2027-12** | 5 年 |
| 6.6 | 2023-10 | **2027-12** | 約 4 年 |
| 6.12 | 2024-11 | 2028-12 | 約 4 年 |
| 6.18 | 2025-11 | 2028-12 | 約 3 年 |

2023 年に Greg KH が LTS を 6 年から原則 2 年に短縮すると表明(保守負荷と、古い LTS の
実利用者・テスターの減少が理由)。実際には利用状況に応じて延長され **実質 4 年前後**に
落ち着いているが、5.10 時代の「LTS に 6 年座り続ける」前提は崩れた。

## BSP カーネルモデルへの含意

- ベンダー BSP の伝統的モデル「LTS を 1 つ選んで製品寿命の間ずっと使う」が成立しにくくなった。
  SoC の製品寿命(5〜10 年)> LTS 寿命(4 年前後)が常態化する
- 6.1 の upstream stable は **2027-12 で終了**。それ以降の選択肢:
  1. **ベンダー自力保守**(Rockchip/Radxa が独自にセキュリティ修正を選別バックポート。鮮度は低下)
  2. **CIP SLTS**: Civil Infrastructure Platform が 6.1 を Super LTS として
     〜2033 年頃まで保守する計画(ただし対象コンフィグ・修正範囲は限定的で、
     BSP がそのまま乗れるわけではない)
  3. **新しい SDK 世代への移行**: Rockchip は develop-6.6 を既に運用中。
     rk3588 系 SDK が 6.6(以降)ベースに移行し、Radxa が新世代パッケージ
     (仮に rk26xx/rk27xx)を出せば E54C も乗り換えられる可能性
  4. **メインライン化**: 根本解。ディストロカーネルの更新に乗れる
- Android は Google が ACK(Android Common Kernel)を kernel.org EOL 後も独自延命するが、
  SBC/組み込み Linux はその恩恵を受けられない

## E54C にとってのウォッチポイント

1. `radxa-pkg` に rk3588 系向けの新世代カーネルパッケージ(6.1.115+ や 6.6 ベース)が現れ、
   その `debian/control` に `linux-image-radxa-e54c` が含まれるか
2. `rockchip-linux/kernel` develop-6.6 の rk3588 系対応の成熟(rk3588 系 SDK の 6.6 移行の前兆)
3. 2027-12(6.1 EOL)までにどの経路が現実化するか — それまでに移行先がなければ
   「upstream 供給の止まった 6.1.84 ベース」で運用を続けることになる
