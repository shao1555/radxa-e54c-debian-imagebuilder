# 11. rockchip-linux 最新への自力追従ワークフローと現実性評価

「E54C のカーネルをせめて rockchip-linux/kernel の最新(develop-6.1 = 6.1.141)に
追従させたい」場合のワークフロー設計と評価。2026-08-22 時点の実測に基づく。

## 前提となる実測事実

追従の難易度を決めるのは「Radxa がベンダーツリーに足している差分(board delta)の大きさ」。
E54C について実測した結果、**この差分は非常に小さい**:

| 項目 | 実測結果 |
|---|---|
| E54C の DTS | `rk3588s-radxa-e54c.dts` / `-spi.dts` の 2 ファイル。radxa/kernel の rkr4.1・rkr5.1 両ブランチに存在。**rockchip-linux 本家には無い** |
| DTS の依存 | include はベンダー標準の `rk3588s.dtsi` / `rk3588-rk806-single.dtsi` / `rk3588-linux.dtsi` のみ(Radxa 独自 dtsi に依存しない) |
| カーネル config | `rockchip_linux_defconfig`(ベンダー標準)+ fragment 3 つ(`rk3588_linux.config` はベンダー、`radxa.config` / `radxa_custom.config` が Radxa 分) |
| パッケージング | radxa-pkg/linux-rk2410 の debian/ 一式 + `make deb`(devcontainer)。全部 GPL-3 で fork 可能 |
| カーネル外の部品 | DT オーバーレイは `radxa-overlays-dkms`、無線は各種 dkms として**カーネル外**に分離済み(dkms は新カーネルで再ビルドされるだけ) |

つまり、必要なのは「小さな patch series(DTS 2 枚 + dts/Makefile 1 行 + config fragment 2 つ
+ α)を新しいベースに載せ替え続けること」であり、巨大な BSP フォークの保守ではない。

## Plan A(推奨・第一歩): rkr5.1(6.1.115)へのバンプ

Radxa 自身が保守する新しめのブランチ `linux-6.1-stan-rkr5.1`(= 6.1.115、linux-rk2501 の元)には
**E54C の DTS が既に入っている**(実測)。Radxa がまだ rk3588 系ボードに適用していないだけ。

```
手順:
1. radxa-pkg/linux-rk2410 を fork
2. .gitmodules の src ブランチを linux-6.1-stan-rkr4.1 → linux-6.1-stan-rkr5.1 に変更
3. debian/changelog のバージョンを 6.1.115-<自分の revision> に(rk2410 の control には
   linux-image-radxa-e54c エントリが既にあるのでほぼ流用可)
4. devcontainer で `make deb` → 実機で smoke test(boot / NIC×4 / PCIe NVMe / 温度)
```

- **工数**: 数時間〜1 日。**リスク**: 低(Radxa が自ボード込みで保守している QA 済みスナップショット)
- **効果**: 6.1.84 → 6.1.115(stable 31 リリース分)を即回収
- ここで確立したビルド・検証・インストール手順が Plan B の土台になる

## Plan B(本命): rockchip-linux develop-6.1 の継続追従

### 構成

```
自分の kernel fork = rockchip-linux/kernel develop-6.1
                   + 小さな patch series(E54C DTS ×2、dts Makefile、radxa config fragments)

自分の packaging fork = radxa-pkg/linux-rk2410 ベース(submodule を上記 fork に向ける)

自分の APT リポジトリ = aptly + GitHub Pages
                        (radxa-repo の infra-repo テンプレートをそのまま流用可)
```

> **追記**: この機構(ベース差し替え + パッチ列 + deb 化 + CI)は radxa-repo/bsp が
> 既製品として持っていることが後から判明した。CI を自作せず bsp のプロファイルを
> fork する実装が推奨。詳細は [12-bsp-stable-profiles.md](12-bsp-stable-profiles.md)。

### 継続ワークフロー(GitHub Actions cron、週次〜月次)

```
1. fetch: rockchip-linux/kernel develop-6.1 の新規コミットを取得
2. rebase: 自分の patch series を新 HEAD に載せ替え(series が小さいので衝突は稀)
   ※ 衝突したら手動介入(通知だけ飛ばす)
3. build: devcontainer + crossbuild で make deb(x86_64 ランナーで可)
4. gate: 「ピン留め遅延」— develop の HEAD 直取りではなく、2 週間程度置いた
   コミットを採用(開発ブランチの半焼けコミットを避ける)。rkr タグが出たら優先採用
5. publish: 自前 APT リポジトリへ(バージョンは 6.1.141-<rev>+e54c など Radxa と衝突しない体系に)
6. デバイス側: 自前リポジトリを Pin 高めで追加し apt upgrade で追従。
   カーネルはバージョン付きパッケージ(linux-image-6.1.x-*)なので旧版と並存でき、
   ブート不能時は extlinux メニューから旧カーネルに戻れる
```

- u-boot・radxa-overlays-dkms・rsetup 等は Radxa 公式のまま(変更不要)
- rsdk でイメージごと作り直す場合も `--debs`(ローカル deb 注入、Pin 1999)や
  `-k` オーバーライドでそのまま統合できる

### Plan C(参考): メインライン化

ヘッドレス router 用途なら必要サブシステム(NIC/PCIe/USB)は mainline rk3588s 対応で
かなり揃っており、E54C の DTS を mainline 流に書き起こして upstream に投げる道もある。
効果は最大(Debian 標準カーネルに乗れる)が、初期工数は段違いに大きい。別調査とする。

## 現実性評価

### 結論: **現実的。ただし「無人運転」ではなく「半自動 + 実機テストは手動」なら**

| 観点 | 評価 |
|---|---|
| 技術的難易度 | **低〜中**。board delta が小さい(実測)、パッケージング基盤流用可、GPU/VPU blob 非依存のヘッドレス用途、が三拍子揃っている。E54C は自力追従に向いた条件のボード |
| 初期工数 | Plan A: 数時間〜1 日 / Plan B: 1〜3 日(CI・リポジトリ整備込み) |
| 継続工数 | 同期 1 回あたり 0.5〜2 時間(rebase 衝突・実機テスト)。月次なら年 10〜20 時間程度 |
| 主なリスク | ① develop-6.1 は**タグ無しの開発ブランチ**で品質ゲートが無い(→ ピン留め遅延と rkr タグ優先で緩和)② ベンダーツリー内部のドライバ/DT binding 変更で DTS 互換が壊れる(→ rebase 時にビルドは通るが動かない事故。実機 smoke test が必須)③ 実機テストの自動化が難しく、検証が属人化する |
| セキュリティ効果 | stable 修正の取り込み遅延が「Rockchip→Radxa 経由の 1〜2 年」から「自分の同期周期(週〜月)」に短縮。**ただし upstream 6.1.y が止まる 2027-12 以降は develop-6.1 自体も先細る**ため、恒久策ではなく時間稼ぎ |
| 撤退容易性 | 高い。Radxa 公式パッケージに戻すのは apt の Pin を外すだけ。u-boot 等は触っていない |

### 推奨シナリオ

1. **まず Plan A**(rkr5.1 バンプ)で手順・検証系・自前リポジトリを確立(ここまでは低リスク)
2. 運用が回ることを確認してから **Plan B** に拡張(ベースを rockchip-linux develop-6.1 へ)
3. 2027 年(6.1 EOL)が近づいたら、rockchip develop-6.6 の rk3588 系成熟度と
   E54C メインライン化のどちらに乗るかを再評価

### やらない方がよいこと

- develop-6.1 HEAD の無検証・自動デプロイ(開発ブランチ直結は境界デバイスでは本末転倒)
- radxa/kernel との履歴を無視した force merge(差分管理が破綻する。
  「小さな series を rebase」の形を崩さないことが持続可能性の核)
