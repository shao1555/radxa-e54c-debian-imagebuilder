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
| [modules/](modules/) | **機能単位のモジュール**(パッケージ・overlay・build hook・テストを一式で所有)。契約は [docs/modules.md](docs/modules.md) を参照。ssh / default-user / networkd / systemd-resolved / container-host / incus / k3s が組み込み済み |
| [packages.txt](packages.txt) | **base runtime の追加 deb パッケージ**(1 行 1 個、# コメント可。機能単位の追加はモジュール側の `packages.apt` へ) |
| [kernel/](kernel/) | **カーネルのカスタマイズ**: `patches/`(昇順 apply)、`config/`(defconfig への fragment)、`dts/`(in-tree に無い場合のみ投入 → 上流化されたら自動で無効) |

未移行機能の受け皿として `files/`(core overlay)と `hooks/customize.d/*.sh`
(legacy hook)の仕組みも残っているが、新しい機能はモジュールとして書くこと。

## ローカルビルド(devcontainer)

macOS でも Docker があればそのままビルドできる(rsdk と同じ devcontainer 方式。
CI も同一コンテナで実行されるため、ローカルと CI の環境差が出ない)。

```bash
# VS Code の場合: フォルダを開いて "Reopen in Container" → ターミナルで
make            # kernel → rootfs → image を順に実行
make kernel     # 個別実行も可
make image IMG_VERSION=v2026.08.22-2100

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
1. scripts/build-kernel.sh   kernel.org から取得 (lock の SHA256 検証)
                             → patches/dts/config 適用 → linux-image/headers の deb 生成
2. scripts/build-rootfs.sh   modules/ を解決・検証 → config.yaml + packages.txt +
                             modules/*/module.yaml → bdebstrap 設定を生成
                             → mmdebstrap で Debian rootfs 構築 (snapshot 固定)
                             → 自前カーネル deb + Radxa deb (lock 検証済み) 投入
                             → core/module overlay → legacy hooks
                             → module rootfs.customize → initramfs/extlinux 生成
                             → module rootfs.seal → core final seal
3. scripts/build-image.sh    guestfish で GPT イメージ化(config/ESP/rootfs の
                             Radxa 互換レイアウト)→ 縮小 → U-Boot 書き込み → xz
```

main への push で CalVer タグ(`vYYYY.MM.DD-HHMM`、JST)の Release に
イメージ・SHA512・manifest・bdebstrap.yaml・dependencies.lock.yaml・
resolved-modules.yaml・provenance.yaml(ビルドの完全な記録)が公開される。

CI は **devcontainer (arm64/amd64) / kernel / rootfs / image / boot-test / release の
7 ジョブ**のパイプライン(ステージごとにキャッシュ・リトライできる粒度に分割):

- **devcontainer**: ビルド環境イメージを .devcontainer の内容ハッシュのタグで GHCR に
  構築(digest 固定ベース + APT snapshot 固定なので、同じ内容なら再利用し続ける)。
  下流ジョブはこのタグを **plain `docker run` するだけ**で、イメージ構築を行わない
- **kernel**: 入力(config.yaml の kernel セクション / kernel/ / lock / seed)の
  ハッシュでキャッシュされ、変更が無ければ数秒でスキップ。ミス時も ccache で短縮
- **rootfs**: 入力の content hash でキャッシュ(セキュリティ更新は週次の snapshot
  更新 PR で取り込む)。どちらの経路でも **smoke test**(framework invariant +
  各モジュールの rootfs test)が走る。PR では再現性検証(二重ビルドの manifest
  一致)も行う。ローカルは `make check`
- **image / boot-test**: snapshot 固定済みの amd64 devcontainer 内で実行
  (x64 ランナーは KVM が使えるため libguestfs が速い)。boot-test は QEMU で
  実ブートし、シリアルログイン → core + 全モジュールの boot test → 実 SSH ログイン
- **release**: main への push のみ。リリース作成だけの最小権限ジョブ
- 権限は最小化(workflow 既定 contents: read、GHCR push は devcontainer のみ)。
  action はサプライチェーン対策として**コミット SHA で固定**

## ログイン

- **リリースイメージ**: ユーザー `debian` / パスワード `debian`(公開値)。
  **初回ログイン時にパスワード変更を強制される**(既知パスワードのままの運用を防ぐ)。
  変更後は公開鍵運用への移行を推奨。公開値である以上、初回起動〜初回ログインの間は
  誰でもログインできるため、**初回セットアップは信頼できる隔離ネットワーク
  (直結ケーブル等)で行うこと**
- **自分でビルドする場合**: `cp .env.example .env` して `DEFAULT_PASSWORD` を
  設定しないと `make rootfs` が失敗する。パスワードはビルド成果物の
  bdebstrap.yaml には埋め込まれない(フック実行時の環境変数参照)
- **パスワード認証の無効化**: 公開鍵を配置したら
  `/etc/ssh/sshd_config.d/10-e54c-server.conf` の 1 行を `no` に変えるだけ
- **SSH ホスト鍵**: イメージには焼き込まれず(全端末が同一鍵を共有してしまうため)、
  各端末の初回起動時に trixie 標準の `sshd-keygen.service` が生成する

## 再現可能ビルド(依存の固定と更新)

ビルド時の外部依存(Debian snapshot、kernel tarball、k3s、Radxa deb、
ビルド環境コンテナ)は [dependencies.lock.yaml](dependencies.lock.yaml) で固定され、
更新は Renovate と週次の snapshot 更新 PR で管理される。
設計・更新手順・障害時の復旧は [docs/reproducible-build.md](docs/reproducible-build.md) を参照。

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
- **初回起動時の容量拡張**: rootfs パーティションは `cloud-initramfs-growroot` が
  initramfs 内で、ファイルシステムは fstab の `x-systemd.growfs` が起動時に
  メディアの残容量まで拡張する(配布イメージは最小サイズまで縮小されている)
- **eMMC 搭載個体**: BootROM は SPI → eMMC → SD の順にブートするため、eMMC に
  OS が入っている個体では SD が無視される。必要なら Radxa 公式手順で eMMC を消去する
- **状態**(macOS + Docker の devcontainer で検証済み):
  - ✅ devcontainer イメージのビルド
  - ✅ **rootfs のフルビルド**(282 パッケージ、incus/lxc/nftables/k3s/u-boot 収録、
    files overlay・hooks・Radxa リポジトリ pin すべて動作確認済み)
  - ✅ guestfish のアプライアンス起動(KVM 無し環境は force_tcg 自動適用、起動 ~10 秒)
  - ✅ **カーネルビルド**(linux 7.2 + 同梱 DTS、フルビルド 23 分 / 増分 2 分 @ Apple Silicon 8 コア。
    `rk3582-radxa-e54c.dtb`・`rtl8365mb.ko`(DSA スイッチ)・`dwmac-rk.ko`(GMAC)の同梱を検収済み)
  - ✅ **`make all` の通し実行**(kernel → rootfs → image、49 分 41 秒 @ Apple Silicon 8 コア。
    GPT レイアウト・rootfs 縮小(8GiB 確保 → 3.1GiB)・sector 64 の idbloader(RKNS
    マジック)まで検分済み。残るは実機での SD ブート確認のみ)

## ライセンス

[GPL-2.0](LICENSE)。`kernel/dts/rk3582-radxa-e54c.dts` は upstream パッチ
(Chukun Pan 氏、GPL-2.0+ OR MIT)由来で、元のライセンス表記を保持している。
