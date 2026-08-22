# 12. bsp の linux プロファイル構造 — 「upstream stable + パッチ集」の既製機構

[radxa-repo/bsp](https://github.com/radxa-repo/bsp) の `linux/.stable-6.1` に大量のパッチがある、
という発見の意味づけ。結論: **bsp はカーネルビルドの 2 系統を持っており、
「ベースを差し替えてパッチ列を当てて deb 化する」という [11-tracking-rockchip-develop.md](11-tracking-rockchip-develop.md)
の Plan B の機構を、そのまま既製品として提供している**。

## bsp の linux ビルドの 2 系統(実測)

### 系統 1: ベンダーカーネル系プロファイル(`rockchip`, `rk2312`, `rk2410`, `rk356x`, `amlogic`)

```
linux/rk2410/fork.conf:
  BSP_GIT="https://github.com/radxa/kernel.git"
  BSP_BRANCH="linux-6.1-stan-rkr4.1"
  BSP_DEFCONFIG="rockchip_linux_defconfig"
  SUPPORTED_BOARDS=( "rk2410" "rock-5a" ... "radxa-e52c" "radxa-e54c" ... )
```

- ソース = radxa/kernel のベンダーブランチ(全部入りなのでパッチはほぼ不要)
- **E54C は `linux/rk2410` プロファイルの SUPPORTED_BOARDS に明記されている**
- `./bsp linux rk2410 radxa-e54c` 相当でベンダーカーネルの deb を作れる
  (radxa-pkg/linux-rk2410 の `make deb` と同じ成果物の別ルート)

### 系統 2: upstream stable 系プロファイル(`stable` → `.stable-6.1`、`latest`、`.stable-6.6`、`.stable-6.12`)

```
linux/.stable-6.1/fork.conf:
  BSP_GIT="https://kernel.googlesource.com/pub/scm/linux/kernel/git/stable/linux.git"
  BSP_TAG="v6.1.68"
  SUPPORTED_BOARDS=("stable" "radxa-zero" "radxa-zero-2pro" "rock-pi-n10" "rock-pi-e" ...)
```

- ソース = **kernel.org の公式 stable ツリーのタグ**(ベンダーツリーではない)
- その上に番号順のパッチディレクトリを重ねる:

| ディレクトリ | 中身(実測) |
|---|---|
| `0001-manjaro-linux` | Manjaro ARM のパッチ 42 枚 |
| `0002-chewitt` | LibreELEC(Christian Hewitt)の Amlogic パッチ |
| `0003-armbian-meson64` / `0006-armbian-rockchip64` | Armbian のパッチ |
| `0004-common` / `0005-mainline` | 共有パッチ(symlink) |
| `0010-backport` | mainline からのバックポート 6 枚 |
| `0020〜0035-*` | ボード別パッチ(radxa-zero, rock-pi-e, rock-s0 …) |
| `0100-vendor` ほか | Radxa 独自 2 枚 + 小物 |

- つまり Radxa は **コミュニティディストロ(Manjaro/LibreELEC/Armbian)のパッチを集約して
  upstream stable に載せる**という、Armbian 型のカーネル保守もやっている。
  APT リポジトリの `linux-stable`(6.1.68)/`linux-latest` パッケージの正体がこれ
- ただし対象は **mainline 対応が成熟した旧世代ボードのみ**(RK3399/RK3328/Amlogic 世代)。
  RK3588/E54C は入っていない
- `.stable-6.12`(v6.12 ベース)は共有パッチのみ・全ボードコメントアウトの**準備中**状態。
  ここに RK3588 系ボードが現れるかは、メインライン移行の良い観測点

## Plan B の実装への影響: CI 自作は不要

[11](11-tracking-rockchip-develop.md) では「GitHub Actions で fetch → rebase → deb 化」を
自作する前提だったが、bsp がこの機構を丸ごと持っているため、実装は大幅に簡略化できる:

```
1. radxa-repo/bsp を fork
2. linux/rk2410/fork.conf を書き換え:
     BSP_GIT="https://github.com/rockchip-linux/kernel.git"
     BSP_BRANCH="develop-6.1"        # または検証済みコミットに BSP_COMMIT で固定
3. Radxa の board delta をパッチディレクトリとして追加:
     linux/rk2410/0200-radxa-boards/
       0001-arm64-dts-add-rk3588s-radxa-e54c.patch   # radxa/kernel から git format-patch で抽出
       0002-configs-add-radxa-config-fragments.patch
4. ./bsp linux rk2410 radxa-e54c  → deb 一式が生成される
5. radxa-pkg/u-boot-rk2410 と同様に、GitHub Actions から bsp@main アクションを呼べば
   CI 化もテンプレ通り(release workflow をコピーして自前 apt リポジトリへ publish)
```

- パッチが当たらなくなったらビルドが止まるだけなので、追従失敗の検知も自動で済む
- ベンダーツリー(develop-6.1)は Radxa の DTS が知らない間に壊れる可能性があるため、
  `BSP_COMMIT` でピン留めし、実機 smoke test 後に進める運用は引き続き推奨

## もう一つの示唆: 「.stable 方式」は E54C の将来の姿

`.stable-6.1` 方式(upstream stable + 小パッチ集)は、mainline 対応が揃ったボードが
ベンダーカーネルを卒業するときの受け皿になっている。E54C にとっては:

- 6.1 の mainline には RK3588 対応がほぼ無いため、**今すぐ E54C を .stable 系に足すのは不可**
- RK3588 の mainline 対応が成熟している 6.12+ 世代の `.stable-6.12`(準備中)に
  RK3588 系ボードとパッチが入り始めたら、それが「ベンダーカーネル卒業」の合図
- そのときの移行コストは「fork.conf にボード追加 + E54C の mainline 流 DTS」であり、
  本ドキュメント群で見てきた構造がそのまま生きる
