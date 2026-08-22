# SPDX-License-Identifier: GPL-2.0-only
FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive \
    LIBGUESTFS_BACKEND=direct

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
        # 開発補助
        sudo less vim-tiny \
    && rm -rf /var/lib/apt/lists/*

# bdebstrap は trixie に無い (bookworm と forky/sid には有る) ため sid から pin 導入
RUN echo 'deb http://deb.debian.org/debian sid main' > /etc/apt/sources.list.d/sid.list \
    && printf 'Package: *\nPin: release a=unstable\nPin-Priority: -1\n\nPackage: bdebstrap\nPin: release a=unstable\nPin-Priority: 500\n' \
        > /etc/apt/preferences.d/bdebstrap-sid \
    && apt-get update && apt-get install -y --no-install-recommends bdebstrap \
    && rm -rf /var/lib/apt/lists/*

# クロスビルド用ツールチェーン (コンテナが arm64 ならネイティブビルドになるため不要)
RUN if [ "$(dpkg --print-architecture)" != "arm64" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            crossbuild-essential-arm64 && rm -rf /var/lib/apt/lists/*; \
    fi

# Radxa APT リポジトリの keyring (mmdebstrap は apt を chroot の外で実行するため、
# signed-by のパスはこのコンテナ側の /usr/share/keyrings が参照される)
RUN curl -fsL "https://radxa-repo.github.io/bookworm/files.list" -o /tmp/files.list \
    && path="$(grep -m1 'radxa-archive-keyring_.*_all\.deb' /tmp/files.list | sed 's|^\./||')" \
    && curl -fL "https://radxa-repo.github.io/bookworm/$path" -o /tmp/radxa-keyring.deb \
    && dpkg -i /tmp/radxa-keyring.deb \
    && rm -f /tmp/radxa-keyring.deb /tmp/files.list

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
