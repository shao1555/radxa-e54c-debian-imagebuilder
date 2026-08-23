#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# container-host モジュールの boot 検査 (QEMU ゲスト内)。
# firewall4 相当の nft ruleset (limit/fib/quota/log/reject/hash/numgen/masq/redir/ct)
# がロードできることを確認する
# shellcheck source=/dev/null
. "$E54C_BOOT_TEST_LIB"

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

exit "$fail"
