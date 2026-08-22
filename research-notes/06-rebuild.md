# 06. 同等イメージを自分でビルドする手順

公式イメージと同じものを手元(または自前 CI)で再現し、カスタムする方法。

## 前提

- rsdk は **devcontainer 前提**の開発環境。ホストは x86_64 でも arm64 でもよい
  (x86_64 の場合は QEMU binfmt で arm64 パッケージのインストールをエミュレートするため遅い)。
- 必要なもの: Docker(または Podman)、VS Code + Dev Containers 拡張、もしくは devcontainer CLI。
- KVM が使えるとイメージ組み立て(libguestfs)が速い。

## 基本手順

```bash
git clone https://github.com/RadxaOS-SDK/rsdk.git
cd rsdk
# VS Code で開いて "Reopen in Container"、または:
npm exec -- @devcontainers/cli up --workspace-folder .
npm exec -- @devcontainers/cli exec --workspace-folder . bash
```

devcontainer 内で:

```bash
src/bin/rsdk setup                       # 初回セットアップ
rsdk build radxa-e54c bookworm cli       # rootfs 生成 + イメージ生成
```

出力は `out/radxa-e54c_bookworm_cli/`:

```
output.img      # イメージ本体(公式の .output.img と同じもの)
rootfs.tar
config.yaml     # 使われた bdebstrap 設定
manifest        # パッケージ一覧
build-image     # 使われた guestfish スクリプト
seed.tar.xz
```

CI(GitHub Actions)で回す場合は radxa-build/radxa-e54c の `build.yaml` がそのまま参考になる
(`RadxaOS-SDK/rsdk/.github/actions/build@main` を呼ぶだけ)。

## 主なカスタマイズポイント

### rsdk build のオプション

| オプション | 効果 |
|---|---|
| `--test-repo` | Radxa の -test リポジトリを使用(test channel 相当) |
| `-m, --mirror <URL>` | Debian ミラー変更(例: `https://ftp.jp.debian.org`) |
| `-M <URL>` | Radxa リポジトリのミラー変更 |
| `--snapshot <timestamp>` | snapshot.debian.org の特定時点でビルド(過去の再現に有用) |
| `-k, --override-kernel <name>` | カーネルメタパッケージ差し替え(例: `-k rock-5a` 相当の別カーネル) |
| `-f, --override-firmware <name>` | U-Boot パッケージ差し替え |
| `--debs <dir>` | **ローカルの .deb を最優先(Pin 1999)で注入**(自前カーネル/パッチ済み deb の検証に便利) |
| `--sdboot` | U-Boot + extlinux ではなく systemd-boot 構成にする |
| `-d, --debug` | rootfs をディレクトリのまま残すデバッグモード |

### パッケージ構成の変更

- 追加パッケージ: `src/share/rsdk/build/rootfs.jsonnet` の `packages+` 配列、
  またはエディション定義 `src/share/rsdk/build/mod/packages/categories/*.libjsonnet` を編集
- 追加カスタマイズ: 同ファイルの `customize-hooks+`
  (`$1` が rootfs。`chroot "$1" ...` で任意コマンド実行可能。雛形コメントあり)

### 過去リリース(b2)の忠実な再現

b2 の `config.yaml` がリリースアセットにあるので、理論上は rsdk を 2025-04-03 時点に checkout し
`--snapshot` で Debian アーカイブを固定すればかなり近いものが再現できる。
ただし Radxa リポジトリ側(radxa-repo.github.io)は最新版しか配信しないため、
Radxa パッケージのバージョンまで完全一致させるには `pkgs.json`(seed.tar.xz 内)に記録された
バージョンの deb を個別に取得して `--debs` で注入する必要がある。

## 関連ドキュメント

- rsdk 公式ドキュメント: https://radxaos-sdk.github.io/rsdk/
- bsp(カーネル/U-Boot のビルド): https://radxa-repo.github.io/bsp/
  - 例: `./bsp linux rk2410` / `./bsp u-boot rk2410 radxa-e54c` でカーネル・U-Boot 単体の deb を作れる
- bdebstrap: https://github.com/bdrung/bdebstrap / mmdebstrap: https://gitlab.mister-muffin.de/josch/mmdebstrap
