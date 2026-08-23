#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""dependencies.lock.yaml から値を取り出す。

使い方:
  lock-get.py kernel.sha256          → 単一値を出力
  lock-get.py radxa.debs             → リストを TSV で出力
                                        (package<TAB>version<TAB>url<TAB>sha256)
シェルスクリプトからの利用を想定し、キーが無い場合は非 0 で終了する。
"""
import re
import sys
from pathlib import Path

import yaml

TOP = Path(__file__).resolve().parent.parent
lock = yaml.safe_load((TOP / "dependencies.lock.yaml").read_text())

if lock.get("schema") != 1:
    print(f"lock-get: 未対応の schema: {lock.get('schema')!r} (期待: 1)", file=sys.stderr)
    sys.exit(1)


def die(msg):
    print(f"lock-get: {msg}", file=sys.stderr)
    sys.exit(1)


node = lock
for part in sys.argv[1].split("."):
    if not isinstance(node, dict) or part not in node:
        die(f"キーが無い: {sys.argv[1]}")
    node = node[part]

if isinstance(node, list):
    seen = set()
    for e in node:
        for k in ("package", "version", "url", "sha256"):
            if not str(e.get(k, "")).strip():
                die(f"{sys.argv[1]}: {e.get('package', '?')} の {k} が空")
        if not re.fullmatch(r"[0-9a-f]{64}", e["sha256"]):
            die(f"{e['package']}: sha256 の書式が不正")
        if not e["url"].startswith("https://"):
            die(f"{e['package']}: url が https でない")
        if e["package"] in seen:
            die(f"{sys.argv[1]}: package が重複: {e['package']}")
        seen.add(e["package"])
        print("\t".join(str(e[k]) for k in ("package", "version", "url", "sha256")))
else:
    print(node)
