# 08. Debian trixie 対応の進捗状況(2026-08-22 時点の実測)

[radxa-repo/trixie-test](https://github.com/radxa-repo/trixie-test) の存在から掘った、
Radxa エコシステムの trixie 対応の現在地。結論: **取り組みは実在し着々と進んでいるが、
E54C を含む Rockchip ボードはまだ「ユーザーランドのみ trixie 配信済み、カーネル/U-Boot は未配信」の段階**。

## APT リポジトリの存在状況

| リポジトリ | 状態 |
|---|---|
| `radxa-repo.github.io/trixie` | **存在・稼働中**(Release 日付 2026-08-20 と活発に更新) |
| `radxa-repo.github.io/trixie-test` | 存在・稼働中(test チャンネル) |
| `radxa-repo.github.io/rk3582-trixie` | **404 — 未作成**(E54C 用 SoC 別リポジトリ) |
| `radxa-repo.github.io/rk3582-trixie-test` | 404 — 未作成 |

GitHub リポジトリ `radxa-repo/trixie(-test)` の構成は bookworm と同じ infra-repo テンプレート
(README + `pkgs.json` + `install.sh` + build/update ワークフロー)。aptly でリポジトリを生成し
GitHub Pages で配信、`update.yaml` が radxa-pkg 各リポジトリの新リリースを追従する。

## trixie リポジトリに「入っているもの / まだ無いもの」

### 入っているもの(pool 実測: 261 ファイル)

- **Radxa ユーザーランド一式**: `radxa-system-config`、`rsetup`、`radxa-firmware`、
  `radxa-bootutils`、各種 dkms、そして **task パッケージ 82 個**
- **`task-radxa-e54c` 0.4.52 も既に配信済み**(radxa-profiles 0.4.52 は pkg.conf で
  buster〜sid、focal〜resolute まで全 suite を配信対象に指定している)

### まだ無いもの

- **カーネルと U-Boot の deb が一切無い**(`pool/main/l/linux-*`、`pool/main/u/u-boot-*` とも 0 件。
  trixie-test 側も同じ)
- ただしバージョン追跡ファイル `pkgs.json` には既に
  `linux-rk2410: 6.1.84-8`、`linux-rk2410-nocsf: 6.1.84-18`、`u-boot-rk2601: 2017.09-73` が
  **ピン留めされており、配信予定リストには載っている**状態
- つまり「リポジトリの器と対象バージョンの選定は済み、Rockchip ベンダーカーネルの
  trixie 向け deb 公開はこれから」という段階

## rsdk 側の対応状況

- rsdk 自体は trixie / sid / Ubuntu noble・resolute をビルド対象としてサポート済み
  (`distributions.json`)
- `products.json` で **trixie を公式サポートに挙げているのは 4 製品のみ**(2026-08 時点):
  - `radxa-zero` / `radxa-zero-2pro`(Amlogic)
  - `radxa-a733`(Allwinner A733)
  - `radxa-dragon-midstream`(Qualcomm、noble/resolute/trixie)
- **Rockchip ボードはまだゼロ**。E54C は引き続き `supported_suite: ["bookworm"]`

## 読み取れるロールアウト順序

1. ✅ rsdk のビルド基盤を trixie 対応(済)
2. ✅ trixie / trixie-test APT リポジトリ開設、ユーザーランド(task-* 含む)配信(済)
3. ✅ 新規 SoC(Amlogic / Allwinner / Qualcomm)のボードから trixie 公式化(進行中)
4. ⬜ Rockchip ベンダーカーネル(linux-rk2410 等)・U-Boot の trixie 向け deb 配信
5. ⬜ SoC 別リポジトリ(rk3582-trixie 等)の開設
6. ⬜ Rockchip ボードの products.json への trixie 追加 → 公式 trixie イメージ

E54C が trixie 公式イメージを得るには 4〜6 が必要。ウォッチすべきは:

- `radxa-repo.github.io/trixie/files.list` に `pool/main/l/linux-rk2410/` が現れるか
- `rk3582-trixie` リポジトリ(GitHub Pages)の出現
- rsdk `products.json` の radxa-e54c エントリの supported_suite

なお [07-vendor-kernel.md](07-vendor-kernel.md) で述べた通り、ベンダーカーネル 6.1 と trixie
ユーザーランドの組み合わせ自体に技術的障壁は薄いので、`task-radxa-e54c` が既に trixie に
ある現状では「trixie rootfs + bookworm リポジトリのカーネル deb を手動混載」する非公式先取りも
構成としては可能(自己責任)。
