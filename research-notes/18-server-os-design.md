# 18. E54C 向け軽量サーバー OS ディストロの設計提案

設計目標: GUI レス・軽量、k8s / LXC ワークロード、**LXC 上で OpenWrt を起動**できること。
リリース時期: Linux 7.3(2026 年 10〜11 月見込み、E54C の DTS 収録が期待される版)以降。

## 推奨(結論)

**ベース = Debian 13 trixie の minimal userland(将来 forky へ移行)+ 自前ビルドの mainline カーネル 7.3.y
+ Incus(LXC)+ k3s。ビルドは bdebstrap/mmdebstrap 直叩き(rsdk 方式の流用)、
配布は aptly + GitHub Pages の自前 APT リポジトリ。**

一言でいうと「Radxa 公式イメージの構造([01](01-overview.md)〜[04](04-image.md))から
ベンダーカーネルだけをメインライン 7.3 に差し替え、エディションを『コンテナホスト』に振った構成」。
この調査で解析してきた部品がほぼそのまま使える。

## ベース候補の比較

| 候補 | k8s | LXC/OpenWrt | 軽さ | カーネル供給 | 保守負荷 | 評価 |
|---|---|---|---|---|---|---|
| **Debian trixie minimal** | ◎ k3s 静的バイナリ / containerd も main に | ◎ **incus 6.0 LTS + lxc 6.0 が main に収録済み** | ○ minimal で 300MB 級 | △ 6.12 なので**カーネルだけ自前**(下記) | 低(userland は Debian security 任せ) | **◎ 推奨** |
| Alpine | ○ k3s は musl でも動く | ○ lxc あり(incus は community) | ◎ 50MB 級 | △ 自前 | 中(musl 起因の互換問題を自分で背負う。glibc 前提のバイナリ・k8s 周辺エコシステムと摩擦) | ○ 「極限まで軽く」なら対抗馬 |
| Armbian フレームワーク流用 | ◎(userland は Debian/Ubuntu) | ◎ | ○ | ○ カーネル deb 化・u-boot・ボード統合が既製([17](17-armbian-e54c.md)) | 低〜中 | ○ 有力な次点。ただし独自ディストロとしての自由度・アイデンティティは下がる |
| Ubuntu Server 26.04 | ◎ | ○ | △ やや重い(snap) | ○ HWE で 2027 年に 7.x 到達見込み | 低 | △ 軽量目標と不整合 |
| Talos Linux | ◎(k8s 専用) | × **LXC 不可** | ◎ | - | - | × OpenWrt in LXC 要件で脱落 |
| Yocto/Buildroot | △ 自前統合 | △ 自前統合 | ◎ | 自前 | **高**(全パッケージの CVE 対応を自分で) | × 汎用サーバー OS には過剰 |

**Debian 推しの決め手**は 3 つ:
1. 要件の 2 本柱が公式パッケージで揃う — **incus 6.0 LTS(LXC 陣営の現行マネージャ)が trixie main に収録済み**、
   k3s は arm64 静的バイナリで載せるだけ
2. userland のセキュリティ更新を Debian security チームに委譲でき([09](09-security-updates.md) の分析どおり)、
   自分が保守するのは**カーネルと自前パッケージだけ**に絞れる
3. ビルドパイプライン(bdebstrap → guestfish)をこの調査で完全に解析済み。実装コストが最小

## アーキテクチャ設計

```
┌─ 配布物: <distro>-e54c_<ver>.img.xz ───────────────────────┐
│ GPT: [16MiB 空き=U-Boot] [config] [ESP 300MiB] [rootfs ext4] │  ← rsdk と同レイアウト
│                                                               │
│ ブート層: vendor U-Boot deb(u-boot-radxa-e54c)+ rkbin blob │  ← 当面 Radxa の deb を流用
│           └ extlinux.conf → 自前カーネル起動(実証済みの構成)│     (7.3 後に mainline U-Boot 検討)
│ カーネル: linux-image-7.3.y-<distro> (自前 deb)              │
│           + E54C DTS(7.3 収録見込み。未収録なら patch 携行)│
│ userland: Debian trixie minimal(mmdebstrap variant=apt)     │
│           + task-<distro>-host メタパッケージ                │
│              (incus, lxc, k3s, nftables, systemd-networkd,  │
│               openssh, 監視系, 自前設定)                     │
└───────────────────────────────────────────────────────────────┘
```

### OpenWrt in LXC のネットワーク設計(E54C の強みが出る部分)

E54C の 4 ポートは DSA なので、**各ポートが独立した netdev(wan/lan1-3)として見える**。
Incus の physical NIC パススルーでポートごとコンテナの netns に移せる:

```bash
# OpenWrt コンテナに wan と lan2/lan3 を物理ごと渡し、lan1 はホスト管理用に残す
incus launch images:openwrt/24.10 router
incus config device add router wan  nic nictype=physical parent=wan
incus config device add router lan2 nic nictype=physical parent=lan2
incus config device add router lan3 nic nictype=physical parent=lan3
```

- OpenWrt イメージは linuxcontainers.org の公式イメージ(`images:openwrt/*`)が incus でそのまま動く
- ホスト側カーネルに OpenWrt の firewall4 が使う nftables/conntrack モジュール群が必要
  → **自前カーネルの config は Debian の arm64 config をベースにする**(モジュール欠けを防ぐ)
  > **実装追記**: imagebuilder の既定は「defconfig + 明示 fragment + ビルド時の反映検証」
  > とした(Debian config ベースはビルド時間が数倍になるため)。fragment の要求値が
  > 依存関係不足で黙って落ちる問題は検証で捕捉する。`kernel.base_config: debian` で
  > Debian config ベースにも切替可能
- ブリッジ構成(スイッチとして使う)と物理パススルー構成(ルーターとして使う)を
  プリセットとして両方用意すると製品価値が出る

### k8s

- フル k8s ではなく **k3s**(または k0s)。RK3582(2×A76+4×A55)+ 4〜8GB クラスでは
  シングルバイナリ + 組込 containerd の k3s が適正。server+agent で常時 ~1GB 弱
- k3s と incus は同居可能。「k3s はネイティブ、ルーター系は incus」の役割分担が素直

## カーネル供給計画(このディストロの核心)

[10](10-lts-lifecycle.md)/[11](11-tracking-rockchip-develop.md) の議論がそのまま適用できる:

1. **anchor は 7.3.y**。7.3 は 2026 年最後のメジャーリリースになる公算が高く、
   慣例(年末リリースが LTS 指定)どおりなら **7.3 が 2026 年の LTS** になる可能性が高い
   (確定は指定発表待ち。外れた場合は 7.2.y→7.3 の追従継続で対応)
2. DTS: 7.3 に Chukun Pan パッチ([16](16-upstream-e54c-patch.md))が入るのが基本線。
   万一遅れても**パッチを 1 枚携行するだけ**(検証環境・手順は docs/15 で確立済み)
3. ビルド: bsp の `.mainline`/`.stable` プロファイル方式([12](12-bsp-stable-profiles.md))か
   Debian 流 `make bindeb-pkg` の CI(GitHub Actions)。週次で 7.3.y stable を追従
4. **出口戦略**: Debian forky(2027 年見込み、7.x 世代)や Ubuntu 26.04 HWE が 7.3+ に達したら
   distro カーネルへ乗り換え、自前保守を終了する。自前カーネル期間は最初の 6〜12 ヶ月限定と
   最初から計画しておく

## ビルド・配布基盤(解析済み部品の流用マップ)

| 機能 | 流用元 | 参照 |
|---|---|---|
| rootfs 生成 | bdebstrap/mmdebstrap + jsonnet 設定(rsdk 方式)or 素の bdebstrap YAML | [03](03-rootfs.md) |
| イメージ化 | guestfish スクリプト(build-image 方式。パーティションレイアウトごと流用可) | [04](04-image.md) |
| APT リポジトリ | aptly + GitHub Pages(radxa-repo 方式)。自前 task メタパッケージと カーネル deb を配信 | [05](05-packages-kernel-uboot.md) |
| CI/リリース | GitHub Actions + Release(radxa-build 方式。config.yaml/manifest の同梱も踏襲推奨) | [02](02-github-actions-release.md) |
| U-Boot | 当面 Radxa の `u-boot-radxa-e54c` deb をそのまま(mainline カーネル起動は実証済み) | [13](13-rkbin.md) |

## タイムライン案

| 時期 | マイルストーン |
|---|---|
| 〜2026-10 | 7.2/7.3-rc + 上流 DTS で実機検証開始(スイッチ・incus/OpenWrt・k3s の PoC)。ビルド CI 整備 |
| 2026-11(7.3 リリース) | alpha: trixie + 7.3.0 + incus/k3s プリインストールイメージ |
| 2026-12〜 | 7.3.y 追従の自動化、LTS 指定の確認、OpenWrt プリセットの作り込み |
| 2027-H1 | beta〜GA。forky freeze の動向を見て userland 移行判断 |
| 2027-H2 | distro カーネル(forky / Ubuntu HWE)への乗り換え評価 → 自前カーネル卒業 |

## 主要リスク

1. **7.3 に E54C DTS が入らない** → 影響小(パッチ携行で回避可能。既に検証済み)
2. **7.3 が LTS 指定されない** → 7.4 以降まで追従を延長。自前保守期間が伸びるだけ
3. rtl8365mb ドライバの初期不具合(VLAN 対応は 7.2 が初出) → PoC 段階で洗い出す。
   フォールバックはベンダーカーネル 6.1 のデュアル提供(rsdk 方式なら容易)
4. RK3582 の選別品個体差(コア無効化は U-Boot が DT を書き換える前提 → vendor U-Boot 継続使用が無難)
