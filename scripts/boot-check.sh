#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# QEMU ゲスト内で root として実行される検査スクリプト。
# boot-test.expect がシリアル経由で転送・実行する。
# 注意: シリアル転送のため各行は短く保つこと (長い行は端末で折返し事故になる)
fail=0
chk() {
	desc="$1"
	cmd="$2"
	if sh -c "$cmd" > /dev/null 2>&1; then
		echo "BOOTCHK ok: $desc"
	else
		echo "BOOTCHK NG: $desc"
		fail=1
	fi
}

chk "自前カーネルで起動 (e54c1)" 'uname -r | grep -q e54c1'
chk "AppArmor 有効" '[ "$(cat /sys/module/apparmor/parameters/enabled)" = Y ]'
chk "systemd-networkd 稼働" 'systemctl is-active systemd-networkd'
chk "systemd-resolved 稼働" 'systemctl is-active systemd-resolved'
chk "sshd 稼働" 'systemctl is-active ssh'
# chk は sh -c で実行するため、外側のシェル変数は参照できない (パスは直書き)
chk "resolv.conf が stub symlink" \
	'[ "$(readlink /etc/resolv.conf)" = ../run/systemd/resolve/stub-resolv.conf ]'

# ホスト側で +2GiB リサイズ済み: growroot + x-systemd.growfs の拡張チェーン検証。
# 縮小済みイメージ (~2.2GiB) + 2GiB なので、拡張成功なら ~3.7GiB、
# 不発なら ~1.7GiB になる。閾値は 3GiB
chk "rootfs が残容量まで拡張 (>3GiB)" '[ "$(findmnt -bno SIZE /)" -gt 3221225472 ]'

# ネットワーク疎通 (QEMU user net。boot-test.sh が en* 用 .network を注入済み)
chk "DHCP で IPv4 取得 (networkd)" \
	'timeout 60 sh -c "until ip -4 addr show scope global | grep -q dynamic; do sleep 2; done"'
chk "デフォルト経路がある" 'ip route | grep -q ^default'
chk "DNS 解決 (resolved スタブ経由)" 'timeout 30 getent hosts deb.debian.org'
chk "外部への HTTP 到達" 'curl -m 30 -fsI http://deb.debian.org'

# firewall4 相当の nft ruleset (limit/fib/quota/log/reject/hash/numgen/masq/redir/ct)
cat > /tmp/fw4test.nft << 'NFT'
table inet fw4test {
	chain syn_flood {
		limit rate 25/second burst 50 packets return
		drop
	}
	chain input {
		type filter hook input priority filter; policy accept;
		iifname "lo" accept
		ct state established,related accept
		tcp flags syn / fin,syn,rst,ack jump syn_flood
		fib saddr . iif oif missing drop
		quota over 10 mbytes log prefix "fw4test: " drop
		reject with icmpx type port-unreachable
	}
	chain forward {
		type filter hook forward priority filter; policy accept;
		meta mark set jhash ip saddr mod 4
		meta mark set numgen inc mod 4
	}
	chain srcnat {
		type nat hook postrouting priority srcnat; policy accept;
		masquerade
	}
	chain dstnat {
		type nat hook prerouting priority dstnat; policy accept;
		tcp dport 8080 redirect to :80
	}
}
NFT
chk "firewall4 相当の nft ruleset ロード" 'nft -f /tmp/fw4test.nft'
chk "nft ruleset が反映されている" 'nft list table inet fw4test | grep -q syn_flood'
# 必ず削除する: input チェーン末尾の reject が残ると、後段の SSH ログイン検査
# を含む新規着信が全て弾かれる (実際に踏んだ)
chk "nft テスト ruleset の削除" 'nft delete table inet fw4test'

# incus は socket activation のため、応答するまでリトライしてから検査する
chk "incus が応答" 'timeout 180 sh -c "until incus info >/tmp/ii 2>&1; do sleep 5; done"'
# incusd は AppArmor を利用できないとき起動ログに warn を出す。それが無いこと
# を確認する (incus info の出力には apparmor の項が無く、直接は判定できない)
chk "incus の AppArmor サポートが無効化されていない" \
	'! journalctl -u incus --no-pager 2>/dev/null | grep -qi "apparmor support has been disabled"'

chk "k3s バイナリ実行可" 'k3s --version'
# k3s は「既定では無効」の設計。初回ブートの preset-all (Debian 既定 enable *)
# が勝手に enable する回帰を実際に踏んだため、preset で disable を固定している
chk "k3s が enable されていない" '[ "$(systemctl is-enabled k3s)" = disabled ]'
chk "k3s が起動していない" '[ "$(systemctl is-active k3s)" = inactive ]'

echo "BOOTTEST_RESULT=$fail"
