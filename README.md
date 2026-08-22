# e54c-server-imagebuilder

Radxa E54C 用の軽量サーバー OS(Debian ベース、GUI レス、incus/LXC + k3s 前提)の
イメージを GitHub Actions でビルドするための imagebuilder。

[e54c-istoreos-imagebuilder](https://github.com/na2na-p/e54c-istoreos-imagebuilder) の
「宣言的な設定 + CI が全部やる」流儀を、Debian + mainline カーネルの構成
([research-notes/18](research-notes/18-server-os-design.md) の設計)に置き換えたもの。
ビルドパイプラインの構造は Radxa 公式 rsdk の解析結果
([research-notes/](research-notes/README.md) の 01〜04)を流用している。
調査ノート一式は [research-notes/](research-notes/README.md) を参照。

## ユーザーが触るのはこの 4 つだけ

| 場所 | 役割 |
|---|---|
| [config.yaml](config.yaml) | **ベースの Debian(suite/mirror)とカーネル(バージョン/localversion)の指定**、U-Boot の供給元 |
| [packages.txt](packages.txt) | **追加 deb パッケージ**(1 行 1 個、# コメント可、`pkg/suite-backports` 形式可) |
| [files/](files/) | **rootfs にそのまま重ねる overlay**(`files/etc/...` → `/etc/...`) |
| [kernel/](kernel/) | **カーネルのカスタマイズ**: `patches/`(昇順 apply)、`config/`(defconfig への fragment)、`dts/`(in-tree に無い場合のみ投入 → 上流化されたら自動で無効) |

`hooks/customize.d/*.sh` に chroot への任意処理を書ける(k3s の静的バイナリ導入が実例)。

## ローカルビルド(devcontainer)

macOS でも Docker があればそのままビルドできる(rsdk と同じ devcontainer 方式。
CI も同一コンテナで実行されるため、ローカルと CI の環境差が出ない)。

```bash
# VS Code の場合: フォルダを開いて "Reopen in Container" → ターミナルで
make            # kernel → rootfs → image を順に実行
make kernel     # 個別実行も可
make image VERSION=v2026.08.22-2100

# devcontainer CLI の場合
npm exec -- @devcontainers/cli up --workspace-folder .
npm exec -- @devcontainers/cli exec --workspace-folder . make
```

- Apple Silicon の Docker ではコンテナが arm64 になるため、**rootfs 構築はネイティブ
  (QEMU 不要)・カーネルもネイティブビルド**になり、CI(amd64 + QEMU/クロス)より速い
- libguestfs は KVM の無い環境(macOS の Docker)では自動で TCG に切り替わる
  (build-image.sh が判定。アプライアンス起動 ~10 秒で実用上問題なし)
- 生成物は `out/` 配下(.gitignore 済み)

## ビルドの流れ(make / CI が実行)

```
1. scripts/build-kernel.sh   kernel.org から取得 → patches/dts/config 適用
                             → クロスビルドで linux-image/headers の deb 生成
2. scripts/build-rootfs.sh   config.yaml + packages.txt → bdebstrap 設定を生成
                             → mmdebstrap で Debian rootfs 構築(QEMU binfmt)
                             → 自前カーネル deb 投入 → files/ overlay → hooks 実行
3. scripts/build-image.sh    guestfish で GPT イメージ化(config/ESP/rootfs の
                             Radxa 互換レイアウト)→ 縮小 → U-Boot 書き込み → xz
```

main への push で CalVer タグ(`vYYYY.MM.DD-HHMM`、JST)の Release に
イメージ・SHA512・manifest・bdebstrap.yaml(ビルドの完全な記録)が公開される。

CI は **devcontainer / kernel / rootfs / image / release の 5 ジョブ**のパイプライン
(artifact 転送は実測で十分速いため、ステージごとにキャッシュ・リトライできる粒度に分割):

- **devcontainer**: ビルド環境イメージを「日付 + .devcontainer 内容ハッシュ」のタグで
  GHCR に構築。同タグが存在すればビルドせず再利用(日次ローテ)。
  下流ジョブはこのタグを **plain `docker run` するだけ**で、イメージ構築を行わない
- **kernel**: 入力(config.yaml / kernel/ / build script)のハッシュでキャッシュされ、
  変更が無ければ数秒でスキップ。ミス時も ccache で再コンパイルを短縮
- **rootfs**: 入力ハッシュ + **日付**でキャッシュ(日次ローテ)。同日の再 push は
  スキップされるが、翌日は必ず fresh な apt 状態で作り直す
  (永続キャッシュにすると Debian のセキュリティ更新が取り込まれなくなるため)
- **image**: guestfish によるイメージ組み立て(rootfs.tar のみを入力に取る)
- **release**: リリース作成のみの最小権限ジョブ。ここだけの失敗は re-run で復旧可
- 権限も最小化: GHCR へ push するのは devcontainer ジョブのみ(packages: write)。
  下流は pull のみ(packages: read)、release は contents: write のみ
- action はサプライチェーン対策として**コミット SHA で固定**(コメントが参照バージョン)

## 設計上の前提と注意

- **カーネル**: mainline 7.3 以降を想定(E54C の DTS 上流化と、DSA スイッチが必要とする
  rtl8365mb VLAN 対応が 7.2 で入ったため)。7.3 に DTS が入るまでは `kernel/dts/` の
  同梱 DTS(上流パッチ v2 から復元したもの)が使われる
- **U-Boot**: 当面 Radxa の vendor U-Boot deb(`u-boot-radxa-e54c`)を流用する。
  vendor U-Boot + extlinux で mainline カーネルが起動することは実証済みで、
  RK3582 の選別コア無効化(DT 書き換え)も vendor U-Boot が担ってくれる
- **ネットワーク設計**: `lan1` のみホスト管理(DHCP)。`wan`/`lan2`/`lan3` は
  OpenWrt コンテナへの物理払い出し用に未設定で残している
  ```bash
  incus launch images:openwrt/24.10 router
  incus config device add router wan nic nictype=physical parent=wan
  ```
- **eMMC 搭載個体**: BootROM は SPI → eMMC → SD の順にブートするため、eMMC に
  OS が入っている個体では SD が無視される。必要なら Radxa 公式手順で eMMC を消去する
- **状態**(macOS + Docker の devcontainer で検証済み):
  - ✅ devcontainer イメージのビルド
  - ✅ **rootfs のフルビルド**(282 パッケージ、incus/lxc/nftables/k3s/u-boot 収録、
    files overlay・hooks・Radxa リポジトリ pin すべて動作確認済み)
  - ✅ guestfish のアプライアンス起動(KVM 無し環境は force_tcg 自動適用、起動 ~10 秒)
  - ✅ **カーネルビルド**(linux 7.2 + 同梱 DTS、フルビルド 23 分 / 増分 2 分 @ Apple Silicon 8 コア。
    `rk3582-radxa-e54c.dtb`・`rtl8365mb.ko`(DSA スイッチ)・`dwmac-rk.ko`(GMAC)の同梱を検収済み)
  - ⬜ イメージ組み立ての通し実行(カーネル入り rootfs での `make rootfs` → `make image`)は未実施

## ライセンス

[GPL-2.0](LICENSE)。`kernel/dts/rk3582-radxa-e54c.dts` は upstream パッチ
(Chukun Pan 氏、GPL-2.0+ OR MIT)由来で、元のライセンス表記を保持している。
