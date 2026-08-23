#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Debian snapshot のタイムスタンプを最新の正準値へ更新する。

dependencies.lock.yaml と .devcontainer/Dockerfile の両方を書き換える
(2 箇所は scripts/verify-build-env.sh がビルド時に一致検証するため、必ず同時に
更新する)。週次の update-snapshot workflow から呼ばれる。手動実行も可。
変更が無ければ何もしない。
"""
import re
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

TOP = Path(__file__).resolve().parent.parent
LOCK = TOP / "dependencies.lock.yaml"
DOCKERFILE = TOP / ".devcontainer" / "Dockerfile"


def canonical_snapshot(archive):
    """今この瞬間のタイムスタンプを投げ、redirect 先の正準タイムスタンプを得る"""
    now = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    url = f"https://snapshot.debian.org/archive/{archive}/{now}/"
    req = urllib.request.Request(url, method="HEAD")

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *args, **kwargs):
            return None

    opener = urllib.request.build_opener(NoRedirect)
    try:
        opener.open(req, timeout=60)
    except urllib.error.HTTPError as e:
        if e.code in (301, 302):
            loc = e.headers["Location"]
            m = re.search(rf"/archive/{re.escape(archive)}/(\d{{8}}T\d{{6}}Z)/", loc)
            if m:
                return m.group(1)
        raise
    print(f"エラー: {archive} の正準 snapshot を解決できない", file=sys.stderr)
    sys.exit(1)


def replace_once(path, pattern, repl):
    text = path.read_text()
    new_text, n = re.subn(pattern, repl, text, flags=re.MULTILINE)
    if n != 1:
        print(f"エラー: {path} で置換対象を特定できない ({pattern!r}, {n} 件)", file=sys.stderr)
        sys.exit(1)
    path.write_text(new_text)


def main():
    snap = canonical_snapshot("debian")
    sec = canonical_snapshot("debian-security")
    old = re.search(r'^\s*snapshot: "(\d{8}T\d{6}Z)"', LOCK.read_text(), re.M).group(1)
    if (snap, sec) == tuple(
        re.findall(r'^\s*(?:security_)?snapshot: "(\d{8}T\d{6}Z)"', LOCK.read_text(), re.M)
    ):
        print(f"snapshot は最新 ({snap} / {sec})。変更なし")
        return
    replace_once(LOCK, r'^(\s*snapshot: ")\d{8}T\d{6}Z(")', rf"\g<1>{snap}\g<2>")
    replace_once(LOCK, r'^(\s*security_snapshot: ")\d{8}T\d{6}Z(")', rf"\g<1>{sec}\g<2>")
    replace_once(DOCKERFILE, r"^(ARG DEBIAN_SNAPSHOT=)\S+$", rf"\g<1>{snap}")
    replace_once(DOCKERFILE, r"^(ARG DEBIAN_SECURITY_SNAPSHOT=)\S+$", rf"\g<1>{sec}")
    print(f"updated: {old} -> {snap} (security: {sec})")


if __name__ == "__main__":
    main()
