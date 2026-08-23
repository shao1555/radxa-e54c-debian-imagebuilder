#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# container-host モジュールの rootfs 検査。
# kernel/config/e54c.config の fragment が要求するコンテナ用途の kernel module
# (=m) が成果物に収録されていることを固定する
# (debian ベース config は CONFIG_MODULE_COMPRESS_XZ=y のため .ko.xz になる)
set -u
# shellcheck source=/dev/null
source "$E54C_TEST_LIB"

check "sysctl 設定 (forwarding / inotify / keys / max_map_count)" \
	'\./etc/sysctl\.d/99-e54c-server\.conf$'
check "nft (実行可)" '^-rwx.* \./usr/sbin/nft$'

# OpenWrt firewall4 の標準 ruleset が必要とする nft モジュール群
for m in nft_limit nft_log nft_redir nft_quota nft_numgen nft_hash nft_fib_inet \
	nft_ct nft_nat nft_masq nft_reject; do
	check "nft モジュール: $m" "/${m}\\.ko(\\.(gz|xz|zst))?\$"
done

# incus / k3s が共有する kernel 前提 (veth / bridge / overlayfs / vxlan /
# wireguard / IPVS)。fragment で =m を要求しているものに合わせる
for m in veth bridge overlay vxlan wireguard ip_vs ip_vs_rr; do
	check "kernel モジュール: $m" "/${m}\\.ko(\\.(gz|xz|zst))?\$"
done

exit "$fail"
