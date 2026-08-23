#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# systemd-resolved モジュールの rootfs 検査
set -u
# shellcheck source=/dev/null
source "$E54C_TEST_LIB"

enabled "systemd-resolved が enable" 'sysinit\.target\.wants/systemd-resolved\.service' 'systemd-resolved\.service'
check "resolv.conf が resolved の stub へ symlink" \
	'^l.* \./etc/resolv\.conf -> \.\./run/systemd/resolve/stub-resolv\.conf$'
# (.bak の漏洩防止は resolved の有無によらない core invariant のため
#  core smoke test が所有する)

exit "$fail"
