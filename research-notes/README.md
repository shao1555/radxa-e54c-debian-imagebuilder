# Radxa E54C 公式 Debian イメージのビルド過程 調査ドキュメント

`radxa-e54c_bookworm_cli_b2.output.img.xz`(https://docs.radxa.com/en/e/e54c/download で配布)が
Debian のソースからどのように作られているかを調査した結果のまとめ。調査日: 2026-08-22。

## TL;DR

- 配布イメージは GitHub リポジトリ [radxa-build/radxa-e54c](https://github.com/radxa-build/radxa-e54c) の
  GitHub Actions(release チャンネル)で、Radxa の新 SDK **[RadxaOS-SDK/rsdk](https://github.com/RadxaOS-SDK/rsdk)** を使ってビルドされている。
  `b2` はリリースタグ `rsdk-b2`(release channel の build #2、2025-04-03 ビルド)に対応する。
- rootfs は **Debian bookworm 公式アーカイブ(deb.debian.org)から `mmdebstrap`(ラッパーは `bdebstrap`)で直接構築**される。
  Debian を改造した独自ベースではなく、素の Debian に Radxa の APT リポジトリ
  (`radxa-repo.github.io/bookworm` と `radxa-repo.github.io/rk3582-bookworm`)を足し、
  カーネル・U-Boot・ボード設定パッケージを上乗せした構成。
- イメージ化(パーティショニング、rootfs 展開、U-Boot 書き込み)は libguestfs の **guestfish** スクリプト
  (`build-image`)で行われる。
- カーネルは **radxa/kernel の `linux-6.1-stan-rkr4.1` ブランチ**(Rockchip ベンダーカーネル 6.1)を
  [radxa-pkg/linux-rk2410](https://github.com/radxa-pkg/linux-rk2410) が deb 化したもの。
  U-Boot は **radxa/u-boot `next-dev-v2024.10`(Rockchip 2017.09 系)+ rkbin のブロブ**を
  [radxa-repo/bsp](https://github.com/radxa-repo/bsp) がビルドしたもの。
- ビルドの完全な設定はリリースアセット `radxa-e54c_bookworm_cli_b2.config.yaml`(bdebstrap 設定)と
  `*.build-image`(guestfish スクリプト)として **イメージと一緒に公開されており**、そこから再現可能。

## ドキュメント構成

| ファイル | 内容 |
|---|---|
| [01-overview.md](01-overview.md) | ビルドパイプライン全体像と登場リポジトリの関係図 |
| [02-github-actions-release.md](02-github-actions-release.md) | radxa-build/radxa-e54c の GitHub Actions とリリースアセットの意味 |
| [03-rootfs.md](03-rootfs.md) | rootfs 生成の詳細(mmdebstrap 設定、APT ソース、パッケージ構成、フック) |
| [04-image.md](04-image.md) | .img 組み立ての詳細(guestfish、パーティション構成、U-Boot 書き込み) |
| [05-packages-kernel-uboot.md](05-packages-kernel-uboot.md) | カーネル・U-Boot・task パッケージの出自と Radxa APT リポジトリの仕組み |
| [06-rebuild.md](06-rebuild.md) | 自分で同じイメージをビルド/カスタマイズする手順 |
| [07-vendor-kernel.md](07-vendor-kernel.md) | Rockchip ベンダーカーネルの解説とディストロ選択への影響 |
| [08-trixie-status.md](08-trixie-status.md) | Debian trixie 対応の進捗状況(APT リポジトリ実測) |
| [09-security-updates.md](09-security-updates.md) | ベンダーカーネルとセキュリティ更新の供給モデル |
| [10-lts-lifecycle.md](10-lts-lifecycle.md) | Rockchip 本家の stable 追従と LTS 短命化の影響 |
| [11-tracking-rockchip-develop.md](11-tracking-rockchip-develop.md) | rockchip-linux 最新への自力追従ワークフローと現実性評価 |
| [12-bsp-stable-profiles.md](12-bsp-stable-profiles.md) | bsp の linux プロファイル構造(upstream stable + パッチ集の既製機構) |
| [13-rkbin.md](13-rkbin.md) | rkbin とは何か(Rockchip ファームウェア blob と加工ツール) |
| [14-mainline-rk3588.md](14-mainline-rk3588.md) | メインラインカーネルの RK3588 対応状況と「DTS だけで済むか」の評価 |
| [15-e54c-mainline-dts.md](15-e54c-mainline-dts.md) | mainline 版 E54C DTS の作成記録(E52C/E54C 比較・翻訳マッピング・検証) |
| [16-upstream-e54c-patch.md](16-upstream-e54c-patch.md) | 上流に投稿された公式 E54C パッチとの差分検証(答え合わせ) |
| [17-armbian-e54c.md](17-armbian-e54c.md) | Armbian の E54C サポートの実装レベル(Radxa 公式・メインラインとの比較) |
| [18-server-os-design.md](18-server-os-design.md) | E54C 向け軽量サーバー OS ディストロの設計提案(ベース選定・アーキテクチャ・タイムライン) |
| [19-kernel-config-comparison.md](19-kernel-config-comparison.md) | kernel config 比較: Debian ベース化 (Issue #2) — Radxa/Rockchip config との突き合わせで不足なしと結論 |

## 実装

18 の設計を実装した imagebuilder が**このリポジトリ本体**(リポジトリルート)である。
宣言的設定(config.yaml / packages.txt / files/ / kernel/)と実行系(scripts/ + GitHub Actions)を
分離した構成で、詳細は [ルートの README](../README.md) を参照。
このディレクトリは、その設計に至るまでの調査ノート(research notes)を残したもの。
