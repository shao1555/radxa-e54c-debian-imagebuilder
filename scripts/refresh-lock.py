#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""dependencies.lock.yaml の kernel / k3s の url と sha256 を version から再導出する。

Renovate は version しか更新できないため、この script が同一 PR 内で url/sha256 を
追随させる (lock-refresh workflow から呼ばれる。手動実行も可)。
sha256 は upstream の公式チェックサムファイルから取得する (本体のダウンロード不要):
  - kernel: https://cdn.kernel.org/pub/linux/kernel/vX.x/sha256sums.asc
  - k3s:    release asset の sha256sum-arm64.txt

コメントを保持するため YAML の再シリアライズはせず、対象行のみ置換する。
変更が必要な場合のみファイルを書き換え、exit 0。整合済みなら何もしない。
"""
import re
import sys
import urllib.request
from pathlib import Path

import yaml

TOP = Path(__file__).resolve().parent.parent
LOCK = TOP / "dependencies.lock.yaml"


def fetch(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read().decode()


def section_replace(text, section, key, value):
    """トップレベル section 内の `key: "..."` 行の値だけを置換する"""
    pattern = re.compile(
        rf'(^{section}:\n(?:^(?:[ \t].*)?\n)*?^[ \t]+{key}: ")[^"]*(")', re.MULTILINE
    )
    new_text, n = pattern.subn(rf"\g<1>{value}\g<2>", text)
    if n != 1:
        print(f"エラー: {section}.{key} の行を特定できない (置換 {n} 件)", file=sys.stderr)
        sys.exit(1)
    return new_text


def main():
    lock = yaml.safe_load(LOCK.read_text())
    text = LOCK.read_text()
    changed = []

    # --- kernel ---
    ver = lock["kernel"]["version"]
    if "-rc" in ver:
        print(f"kernel {ver} は rc 版のため tarball lock の対象外 (スキップ)")
    else:
        major = ver.split(".")[0]
        url = f"https://cdn.kernel.org/pub/linux/kernel/v{major}.x/linux-{ver}.tar.xz"
        sums = fetch(f"https://cdn.kernel.org/pub/linux/kernel/v{major}.x/sha256sums.asc")
        m = re.search(rf"^([0-9a-f]{{64}})\s+linux-{re.escape(ver)}\.tar\.xz$", sums, re.M)
        if not m:
            print(f"エラー: kernel.org の sha256sums に linux-{ver}.tar.xz が無い", file=sys.stderr)
            sys.exit(1)
        sha = m.group(1)
        if lock["kernel"]["url"] != url or lock["kernel"]["sha256"] != sha:
            text = section_replace(text, "kernel", "url", url)
            text = section_replace(text, "kernel", "sha256", sha)
            changed.append(f"kernel {ver}")

    # --- k3s ---
    kver = lock["k3s"]["version"]
    url = f"https://github.com/k3s-io/k3s/releases/download/{kver}/k3s-arm64"
    sums = fetch(f"https://github.com/k3s-io/k3s/releases/download/{kver}/sha256sum-arm64.txt")
    m = re.search(r"^([0-9a-f]{64})\s+k3s-arm64$", sums, re.M)
    if not m:
        print(f"エラー: k3s {kver} の sha256sum-arm64.txt に k3s-arm64 が無い", file=sys.stderr)
        sys.exit(1)
    sha = m.group(1)
    if lock["k3s"]["url"] != url or lock["k3s"]["sha256"] != sha:
        text = section_replace(text, "k3s", "url", url)
        text = section_replace(text, "k3s", "sha256", sha)
        changed.append(f"k3s {kver}")

    if changed:
        LOCK.write_text(text)
        print(f"updated: {', '.join(changed)}")
    else:
        print("lock は整合済み (変更なし)")


if __name__ == "__main__":
    main()
