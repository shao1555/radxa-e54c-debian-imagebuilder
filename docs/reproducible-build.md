# 再現可能ビルドの設計と運用 (Issue #4)

目標は bit-for-bit 同一のイメージではなく、**同じコミットと
`dependencies.lock.yaml` から同じ依存バージョン集合を再解決でき、
更新差分をレビューできる**こと。

## 設計

### 依存の固定方法

| 依存 | 固定方法 | 検証 |
|---|---|---|
| Debian パッケージ (rootfs) | snapshot.debian.org の正準タイムスタンプ (`debian.snapshot` / `security_snapshot`) | apt の GPG 署名 + PR での再現性検証 |
| Debian パッケージ (ビルド環境) | 同上 (Dockerfile の `ARG DEBIAN_SNAPSHOT`) | `scripts/verify-build-env.sh` が lock と Dockerfile 由来のマーカー (`/etc/e54c-snapshot`) の一致をビルド時に検証 |
| devcontainer ベースイメージ | `debian:trixie@sha256:...` (immutable digest) | lock の `devcontainer.base_image` と Dockerfile の FROM を対で管理 |
| kernel tarball | version + URL + SHA256 | ダウンロード時 (キャッシュ済みでも) に毎回 sha256sum。config.yaml との版不一致は fail-fast |
| k3s バイナリ | version + URL + SHA256 | ダウンロード時に sha256sum (スキップ不可) |
| Radxa deb (keyring / U-Boot) | version + URL + SHA256 の 3 点固定。apt 解決はしない | sha256sum + `dpkg-deb -f` の Package/Version 照合。upstream から消えると検出 |
| GitHub Actions | コミット SHA 固定 | Renovate (`pinDigests`) が維持 |

- lock の読み出しは `scripts/lock-get.py`。**どのキーの取得でも lock 全体を
  検証**してから値を返す (schema、必須フィールド、sha256 書式、https、
  radxa 必須 3 パッケージ、制御文字拒否)
- 生成された rootfs の apt sources は **live リポジトリに書き戻される**
  (配備後の security update を妨げない)。snapshot URL の残留は smoke test が拒否する
- Radxa リポジトリの sources.list + pin + keyring は成果物に残す
  (配備後の U-Boot 更新経路。ビルド時の apt は radxa リポジトリに触れない)

### キャッシュと provenance

- CI のキャッシュキーは日付を含まず、入力 (lock、config の kernel セクション、
  スクリプト、devcontainer イメージ識別子、linux-config seed バージョン) の
  content hash のみで構成する
- リリースには provenance を同梱する: `dependencies.lock.yaml`、rootfs の
  package/version manifest、ビルド環境 (arm64/amd64 devcontainer) のパッケージ
  一覧、ソースコミット、コンテナ digest (`provenance.yaml`)、イメージの SHA512
- 成果物を左右するツールチェーンはすべて snapshot 固定済み devcontainer 内で
  実行する (kernel / rootfs / image / boot-test の全ジョブ。ランナーへの
  `apt-get install` は行わない)

### 検証 (PR)

release workflow は pull_request でも release 以外の全ジョブを実行する:

1. devcontainer 再構築 (Dockerfile が変わった場合)
2. kernel / rootfs / image / QEMU boot-test のフルチェーン
3. **再現性検証**: rootfs を同じ lock からもう一度解決し、package/version
   manifest の完全一致を確認
4. **manifest 差分**: 最新リリースの manifest との diff を job summary に表示
   (追加・削除・version 変更のレビュー用)

## 更新手順

### Debian snapshot (週次・自動)

`update-snapshot` workflow (月曜 06:00 JST) が最新の正準タイムスタンプで
lock + Dockerfile を更新する PR を作成し、検証 CI を起動する。
レビュー観点: rootfs job summary の manifest 差分と boot-test の結果。
自動マージはしない。手動実行は Actions の workflow_dispatch から。

### kernel / k3s (Renovate)

Renovate が lock の `# renovate:` アノテーションを見て version 更新 PR を作る。
url / sha256 は `lock-refresh` workflow が upstream の公式チェックサム
(kernel.org の sha256sums.asc / k3s release の sha256sum-arm64.txt) から
再導出して同じ PR に追随コミットし、検証 CI を再起動する。

kernel の version は config.yaml と lock の両方にあり、不一致はビルドが
fail-fast で検出する。kernel を更新する PR では config.yaml も揃えること。

### Radxa deb (手動)

自動更新はしない。更新時は `radxa-repo.github.io/bookworm/files.list` から
新しい deb のパスを確認し、ダウンロードして sha256 を取り、lock の
`radxa.debs` (keyring / u-boot-rk2601 / u-boot-radxa-e54c の 3 点) を書き換える。
upstream から旧 deb が消えるとビルドが失敗して検出される。
恒久 mirror の設計は別 Issue。

### devcontainer ベースイメージ

Renovate の dockerfile manager が FROM の digest 更新 PR を作る。
lock の `devcontainer.base_image` も同じ値に揃えること
(lock-get が digest 形式を検証する)。

## 障害時の復旧

- **snapshot.debian.org が落ちている / 遅い**: ビルドは失敗するが成果物は
  壊れない。復旧を待つか、直近の成功キャッシュ (kernel deb / rootfs) が
  生きていれば CI はそれを使って通る
- **upstream から artifact が消えた** (kernel tarball / k3s / Radxa deb):
  sha256 検証か 404 でビルドが失敗する。lock を新しい版に更新する
  (Radxa deb は files.list から再解決)。過去リリースの再現には
  リリース同梱の lock と manifest を参照する
- **lock と Dockerfile の snapshot がずれた**: `verify-build-env.sh` が
  ビルド時に fail-fast する。`scripts/update-snapshot.py` は両方を同時に
  書き換えるので、手動編集ではなくこれを使う
- **キャッシュ汚染が疑われる場合**: キャッシュキーは入力の content hash
  なので、入力 (lock 等) を変えれば必ず作り直される。強制的に無効化したい
  場合は GitHub Actions のキャッシュを UI から削除する

## 既知の制限 (スコープ外)

- bit-for-bit 再現 (timestamp / UUID / アーカイブメタデータ) は対象外
- QEMU ブートテストは virtio のため、実 SD コントローラ (dw_mmc)・DSA
  スイッチ・dwmac は実動検証されない (smoke test の静的検査 + 実機確認で担保)
- Radxa deb の恒久 mirror は別 Issue
