# 02. GitHub Actions とリリースの仕組み

## radxa-build/radxa-e54c リポジトリ

このリポジトリ自体には**ビルドロジックは一切なく**、README にも
"This repository is only for hosting the GitHub workflows that build the image." とある通り、
ワークフロー置き場 + リリース(イメージ配布)の場所でしかない。

ワークフローは 2 本(どちらも `workflow_dispatch`、つまり手動トリガー):

| ワークフロー | チャンネル | タグ / アセット接尾辞 | 特徴 |
|---|---|---|---|
| `.github/workflows/build.yaml` | release | `rsdk-bN` / `_bN` | 正式リリース。docs.radxa.com からリンクされるのはこれ |
| `.github/workflows/test.yaml` | test | `rsdk-tN` / `_tN` | `test-repo: true` で Radxa の **-test APT リポジトリ**(`bookworm-test` 等)を使う内部検証ビルド |

`b2` = release channel ワークフローの **run_number 2**。リリースタグは `rsdk-b2`(2025-04-03 ビルド)。

## build.yaml の流れ

```yaml
jobs:
  prepare_release:
    steps:
      - Check for existing releases        # タグ rsdk-b${run_number} の重複チェック
      - uses: radxa-repo/rbuild-changelog@main   # 前回リリースとのパッケージ差分 changelog を生成
      - uses: RadxaOS-SDK/rsdk/.github/actions/query@main
        # products.json から radxa-e54c の suites/editions を取得
        # → E54C は suites=["bookworm"], editions=["cli"] のみ
      - uses: softprops/action-gh-release@v3     # 空のプレリリース rsdk-b2 を先に作成
  build:
    strategy:
      matrix:   # product=radxa-e54c × suite=bookworm × edition=cli
    steps:
      - uses: RadxaOS-SDK/rsdk/.github/actions/build@main   # ← 実ビルド
```

## rsdk の build アクション(`RadxaOS-SDK/rsdk/.github/actions/build`)

実ビルドは rsdk リポジトリ側の composite action で行われる:

1. **setup アクション**: rsdk リポジトリを checkout、KVM を有効化、
   `docker/setup-qemu-action`(binfmt)で **arm64 のユーザーモードエミュレーション**を設定
   (ランナーは x86_64 の ubuntu-latest。arm64 rootfs 構築は QEMU 経由)。
2. **devcontainer 内でビルド** (`devcontainers/ci@v0.3`):
   ```bash
   src/bin/rsdk setup
   src/bin/rsdk shell rsdk build <options> --sector-size 512 --image-name "output_512.img" radxa-e54c bookworm cli
   ```
   ※ E54C は `products.json` で `sector_size: [512]` のみなので 512B セクタ版 1 つ。
   ※ b2 時点のアクションは `--image-name output.img` 相当だったため、アセット名が `.output.img` になっている
   (現行 main では `.output_512.img` 形式に変更済み)。
3. **リネームと圧縮**: 出力ディレクトリ `out/radxa-e54c_bookworm_cli/` の各ファイルを
   `radxa-e54c_bookworm_cli_b2.<元ファイル名>` にリネームし、`.img` と `.tar` を `xz -T0` 圧縮、
   `sha512sum` を生成。
4. **リリースへアップロード**し、changelog・ダウンロードリンク・チェックサムをリリース本文に追記。
   失敗時はリリースをロールバック(削除)。

## リリースアセットの意味

`rsdk-b2` リリースに添付されているファイル:

| アセット | 中身 |
|---|---|
| `radxa-e54c_bookworm_cli_b2.output.img.xz` | 完成イメージ(xz 圧縮)。これが配布物 |
| `radxa-e54c_bookworm_cli_b2.rootfs.tar.xz` | イメージ化前の rootfs tarball(mmdebstrap の出力そのもの) |
| `radxa-e54c_bookworm_cli_b2.config.yaml` | **実際に使われた bdebstrap 設定**(bdebstrap が出力ディレクトリに保存するマージ済み設定)。ビルドの完全な記録 |
| `radxa-e54c_bookworm_cli_b2.build-image` | **実際に使われた guestfish スクリプト**(イメージ組み立ての完全な記録) |
| `radxa-e54c_bookworm_cli_b2.manifest` | rootfs にインストールされた全 deb パッケージとバージョンの一覧(1250 個超) |
| `radxa-e54c_bookworm_cli_b2.seed.tar.xz` | `/etc/radxa_image_fingerprint` と `/etc/rsdk/`(config.yaml, pkgs.json スナップショット)の控え |
| `radxa-e54c_bookworm_cli_b2.sha512sum` | チェックサム |
| `changelog.md` | 前リリースからのパッケージバージョン差分 |

**ポイント**: `config.yaml` と `build-image` がアセットとして残っているため、
「このイメージがどう作られたか」はリリースページだけで完全に追跡できる。
rootfs 内にも `/etc/rsdk/config.yaml` と `/etc/radxa_image_fingerprint` として同じ情報が焼き込まれている。

## b2 の実測メタデータ(config.yaml より)

```yaml
metadata:
  architecture: arm64
  build_date: '2025-04-03T08:30:02+00:00'
  edition: cli
  suite: bookworm
  product: radxa-e54c
  variant: apt          # mmdebstrap variant
  mode: root
  vendor_packages: true
  sdboot: false         # systemd-boot ではなく U-Boot + extlinux 起動
env:
  SOURCE_DATE_EPOCH: 1743669002   # 再現性のためのタイムスタンプ固定
```
