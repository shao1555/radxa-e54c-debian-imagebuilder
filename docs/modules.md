# モジュール契約 (`e54c.image/v1alpha1`)

このドキュメントが `v1alpha1` のモジュール契約の**正**である
(Python 実装は本文書に従う。食い違いは実装のバグとして扱う)。
v1alpha1 は破壊的変更があり得る。変更時は本文書と `apiVersion` を同時に更新する。

## 概要

モジュールは「1 つの機能が成果物へ持ち込む一式」を所有する再利用可能な単位で、
以下を宣言できる。

- apt パッケージ
- rootfs への overlay (ファイルツリー)
- build lifecycle hook
- rootfs / boot テスト

MVP (Issue #7) では **`modules/*/module.yaml` を辞書順に探索し、見つかった
すべてのモジュールを自動的に有効化する**。profile による選択、enable/disable、
モジュール間の依存・競合、外部 (Git/OCI) モジュールは未対応
(将来の Issue で扱う)。

## ディレクトリ構造

```text
modules/<module-id>/
├── module.yaml        # 必須。このモジュールの宣言
├── files/             # overlay (任意。module.yaml の overlays が参照)
├── hooks/             # lifecycle hook スクリプト (任意)
└── tests/             # rootfs / boot テストスクリプト (任意)
```

- ディレクトリ名と `metadata.id` は一致必須
- ID の重複、不正な YAML、未知の lifecycle phase は build 開始前に fail-fast
- 解決順 (= hook / テストの実行順) はディレクトリ名の辞書順

## `module.yaml` の形式

```yaml
apiVersion: e54c.image/v1alpha1
kind: Module

metadata:
  id: ssh                      # ディレクトリ名と一致必須
  description: 説明 (任意)

packages:
  apt:                         # mmdebstrap の packages に合流する
    - openssh-server

overlays:
  - source: files              # モジュール内の相対パス (ディレクトリ)
    target: /                  # MVP では "/" のみ。他は fail-fast

hooks:
  rootfs.customize:            # 実行するスクリプト (モジュール内相対パス) のリスト
    - hooks/setup.sh
  rootfs.seal:
    - hooks/remove-host-keys.sh

tests:
  rootfs:
    - tests/rootfs.sh
  boot:
    - tests/boot.sh
```

### スクリプト参照の制限

hook / テストの参照先は resolver が以下を fail-fast で検証する。

- モジュールディレクトリ内の相対パス (絶対パス・`..` は拒否)
- 通常ファイルであること (symlink は拒否。実体解決後もモジュール内に収まること)
- 実行ビットがあること (`chmod +x`)。実行は shebang を尊重した直接実行で、
  `bash <path>` 固定ではない
- inline shell command は書けない (必ずファイルを参照する)

## lifecycle phase と実行順

rootfs 生成の全体順序:

```text
パッケージ導入 (mmdebstrap + 自前 kernel/radxa deb)
→ core files/ + module overlay          … 同一フェーズで適用
→ legacy customize hooks                … 未移行の core 実装 + hooks/customize.d/
→ module rootfs.customize
→ framework boot finalize               … update-initramfs → u-boot-update
→ module rootfs.seal
→ core final seal                       … framework invariant の封印
→ tar 生成
```

- `rootfs.customize` は **boot finalize より前**に実行される。initramfs や
  extlinux に影響する変更 (firmware、`/etc/initramfs-tools/`、kernel cmdline、
  DT overlay 等) を initramfs / extlinux.conf 生成に反映できる
- `rootfs.seal` は boot finalize の後、core final seal の前。成果物の封印処理
  (ビルド時秘匿物の除去など) に使う
- **core final seal は必ずモジュールより後**に実行される (machine-id、
  ビルド時 apt 設定、sources の live 書き戻しなどの framework invariant)。
  モジュールは core の封印処理後に成果物を書き戻せない
- hook には **rootfs のパス (tar 化前の展開済みディレクトリ) が第 1 引数**として
  渡され、builder 上 (chroot 外) で実行される。tar 化後の再展開は行われない

| phase | 実行場所 | MVP |
|---|---|---|
| `rootfs.customize` | boot finalize 前。rootfs path を引数に builder 上で実行 | 対応 |
| `rootfs.seal` | boot finalize 後、core final seal 前 | 対応 |
| `image.finalize` | raw image 作成後 | スキーマ予約のみ |
| `runtime.firstBoot` | 生成端末の初回起動時 | スキーマ予約のみ |
| `tests.rootfs` | rootfs.tar の静的検査 | 対応 |
| `tests.boot` | QEMU guest 内の検査 | 対応 |
| `tests.hardware` | E54C 実機検査 | スキーマ予約のみ |

予約 phase に hook を指定した場合は無視されず「未対応」として明示的に失敗する。
未知の phase 名も失敗する。

## overlay の規則

- overlay は hook ではなく、パッケージ導入後・`rootfs.customize` 前に
  framework が適用する
- MVP では `target: /` のみ
- **同一の非ディレクトリパス**への配置は build 前に競合として失敗する
  (core `files/` と module、module 同士の両方)。ディレクトリの共有は許可
- 暗黙の last-wins は存在しない。profile からの明示 override は将来の Issue

## rootfs テストの契約

テストスクリプトは builder / CI ランナー上で独立プロセスとして実行される。
以下の環境変数が設定される。

| 変数 | 内容 |
|---|---|
| `E54C_MODULE_ID` | 実行中のモジュール ID |
| `E54C_ROOTFS_TAR` | rootfs.tar の絶対パス (内容の抽出検査に使う) |
| `E54C_ROOTFS_LISTING` | `tar -tvf` の出力を保存した一時ファイル (listing はビルドごとに一度だけ生成される) |
| `E54C_TEST_LIB` | 共通 helper。`source "$E54C_TEST_LIB"` して使う |

共通 helper (`scripts/test-lib.sh`) は `check` / `check_absent` / `enabled` /
`tar_cat` と失敗フラグ `$fail` を提供する。スクリプトは末尾で
`exit "$fail"` すること。非 0 終了はモジュール ID と対象スクリプトを表示して
全体を失敗させる。出力には `module[<id>]` が前置される。

モジュールテストは**追加のみ可能**で、core invariant (core smoke test) を
無効化することはできない。

## boot テストの契約

boot テストは QEMU ゲスト内で root として実行される。framework が
core テスト・全モジュールの boot テスト・共通 lib・dispatcher を 1 つの
bundle (tar) にまとめてシリアル経由で 1 回だけ転送し、dispatcher
(`scripts/boot-test-run.sh`) が各テストを**独立した subprocess** で実行する
(同一シェルスコープへの連結だと変数・関数・`exit`・trap が衝突するため)。

- `E54C_BOOT_TEST_LIB` に共通 helper のパスが、`E54C_MODULE_ID` に実行中の
  モジュール ID が設定される (core テストでは空)。
  `. "$E54C_BOOT_TEST_LIB"` で `chk` と `$fail` を得て、末尾で `exit "$fail"`
- 出力には `module[<id>]` が前置され、dispatcher が結果を集約して行頭の
  `BOOTTEST_RESULT` を出力する (モジュール出力は前置により行頭に現れないため、
  最終結果を偽装できない)
- シリアル転送のため各行は短く保つこと
- ホスト側からの実 SSH ログイン検査は core harness (expect) が担当する
  (module テストの host-side phase は将来の Issue)

## provenance

ビルドごとに有効化したモジュール一覧が `out/meta/resolved-modules.yaml` に
生成され、Release に同梱される。

```yaml
apiVersion: e54c.image/v1alpha1
modules:
  - id: ssh
    source: builtin
    path: modules/ssh
```

## 現在未対応のもの (将来の Issue)

- profile の定義・継承・設定上書き、module の enable/disable
- module 間の `requires` / `conflicts` / capability
- 外部 GitHub/Git/OCI module の取得、module lock file と署名検証
- 解決結果 (module plan) の一回生成と全 consumer での共有
- JSON Schema による厳密検証 (`additionalProperties: false`)
- first-boot runner / hardware test runner
