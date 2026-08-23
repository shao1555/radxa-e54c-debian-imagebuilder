# SPDX-License-Identifier: GPL-2.0-only
# ベースイメージと APT は dependencies.lock.yaml と対で固定する
# (値の一致は scripts/verify-build-env.sh がビルド時に照合する)
FROM debian:trixie@sha256:34cd9e9fd437c0a095ec39cb2e73422c9f30821b0d0848ed74fd0d43bae4d958

ENV DEBIAN_FRONTEND=noninteractive \
    LIBGUESTFS_BACKEND=direct

# APT を snapshot.debian.org の固定タイムスタンプに向ける
# (dependencies.lock.yaml の debian.snapshot / security_snapshot と一致させること)
ARG DEBIAN_SNAPSHOT=20260821T205528Z
ARG DEBIAN_SECURITY_SNAPSHOT=20260821T212820Z
# ベースイメージには ca-certificates が無く https を検証できないため http を使う
# (apt は Release/Packages の GPG 署名とハッシュ連鎖で完全性を検証する)
RUN rm -f /etc/apt/sources.list.d/debian.sources \
    && printf 'deb http://snapshot.debian.org/archive/debian/%s/ trixie main\n' "$DEBIAN_SNAPSHOT" \
        > /etc/apt/sources.list \
    && printf 'deb http://snapshot.debian.org/archive/debian/%s/ trixie-updates main\n' "$DEBIAN_SNAPSHOT" \
        >> /etc/apt/sources.list \
    && printf 'deb http://snapshot.debian.org/archive/debian-security/%s/ trixie-security main\n' "$DEBIAN_SECURITY_SNAPSHOT" \
        >> /etc/apt/sources.list \
    # snapshot の Release は Valid-Until が過去日になり得るため無効化する
    && printf 'Acquire::Check-Valid-Until "false";\n' > /etc/apt/apt.conf.d/99snapshot \
    # ビルドスクリプトが lock との一致を照合するためのマーカー
    && printf '%s %s\n' "$DEBIAN_SNAPSHOT" "$DEBIAN_SECURITY_SNAPSHOT" > /etc/e54c-snapshot

RUN apt-get update && apt-get install -y --no-install-recommends \
        # rootfs 構築
        mmdebstrap qemu-user-static binfmt-support \
        apt-utils ca-certificates \
        # カーネルビルド (共通)。libdw-dev は 7.x の bindeb-pkg の Build-Depends、
        # dwarves は CONFIG_DEBUG_INFO_BTF 用の pahole
        build-essential flex bison bc libssl-dev libelf-dev libdw-dev dwarves \
        ccache \
        debhelper kmod rsync cpio git curl xz-utils \
        python3 python3-yaml \
        # イメージ組み立て
        libguestfs-tools gdisk parted \
        # QEMU ブートテスト (scripts/boot-test.sh)
        qemu-system-arm qemu-utils u-boot-qemu ipxe-qemu expect openssh-client \
        # 開発補助
        sudo less vim-tiny \
    && rm -rf /var/lib/apt/lists/*

# bdebstrap は trixie に無い (bookworm と forky/sid には有る) ため sid から pin 導入
# (sid も同じ snapshot タイムスタンプに固定する)
RUN echo "deb https://snapshot.debian.org/archive/debian/$DEBIAN_SNAPSHOT/ sid main" > /etc/apt/sources.list.d/sid.list \
    && printf 'Package: *\nPin: release a=unstable\nPin-Priority: -1\n\nPackage: bdebstrap\nPin: release a=unstable\nPin-Priority: 500\n' \
        > /etc/apt/preferences.d/bdebstrap-sid \
    && apt-get update && apt-get install -y --no-install-recommends bdebstrap \
    && rm -rf /var/lib/apt/lists/*

# クロスビルド用ツールチェーン (コンテナが arm64 ならネイティブビルドになるため不要)
RUN if [ "$(dpkg --print-architecture)" != "arm64" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            crossbuild-essential-arm64 && rm -rf /var/lib/apt/lists/*; \
    fi

# (Radxa keyring の焼き込みは廃止: radxa の deb は dependencies.lock.yaml で
#  固定した URL から取得・sha256 検証して dpkg 投入するため、ビルド時の apt が
#  radxa リポジトリに触れることは無くなった)

# kernel.base_config: debian 用の Debian カーネル config
# (このコンテナのアーキテクチャ分の config が入る。E54C 用途では arm64 で使う)
RUN apt-get update && apt-get install -y --no-install-recommends \
        "linux-config-6.12" \
    && rm -rf /var/lib/apt/lists/*

# libguestfs のアプライアンスがコンテナ内の /boot からカーネルを拾えるようにする
# (コンテナにはホストのカーネルが無いため、パッケージとして入れておく)
RUN apt-get update && apt-get install -y --no-install-recommends \
        "linux-image-$(dpkg --print-architecture)" \
    && rm -rf /var/lib/apt/lists/* \
    && chmod +r /boot/vmlinuz-* || true
