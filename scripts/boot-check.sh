#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# QEMU ゲスト内で root として実行される core 検査 (boot テスト bundle の一部)。
# framework/board invariant のみ。利用目的依存の検査は各モジュールの
# tests/boot.sh が所有する (networkd / systemd-resolved / container-host /
# incus / k3s / ssh)。
# 注意: シリアル転送のため各行は短く保つこと (長い行は端末で折返し事故になる)
# shellcheck source=boot-test-lib.sh
. "$E54C_BOOT_TEST_LIB"

chk "自前カーネルで起動 (e54c1)" 'uname -r | grep -q e54c1'
# (AppArmor の実動作検査は modules/incus が所有する。core に置くと Incus を
#  無効化した profile でも AppArmor を要求してしまう)

# ホスト側で +2GiB リサイズ済み: growroot + x-systemd.growfs の拡張チェーン検証。
# 縮小済みイメージ (~2.2GiB) + 2GiB なので、拡張成功なら ~3.7GiB、
# 不発なら ~1.7GiB になる。閾値は 3GiB
chk "rootfs が残容量まで拡張 (>3GiB)" '[ "$(findmnt -bno SIZE /)" -gt 3221225472 ]'

# 外部への HTTP 到達: DHCP → 経路 → DNS → TCP を貫通する cross-module の
# 受け入れ検査として core に置く (単一モジュールの責務にすると暗黙の
# module 依存が生じる。profiles 導入後は server profile の統合検査へ移す)。
# 一時的な外部障害でリリースを落とさないようリトライする
chk "外部への HTTP 到達" \
	'curl -m 30 -fsI --retry 5 --retry-all-errors --retry-delay 10 http://deb.debian.org'

exit "$fail"
