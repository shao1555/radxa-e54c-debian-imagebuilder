#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""dependencies.lock.yaml から値を取り出す。

使い方:
  lock-get.py kernel.sha256          → 単一値を出力
  lock-get.py radxa.debs             → リストを TSV で出力
                                        (package<TAB>version<TAB>url<TAB>sha256)
シェルスクリプトからの利用を想定し、キーが無い場合は非 0 で終了する。
"""
import sys
from pathlib import Path

import yaml

TOP = Path(__file__).resolve().parent.parent
lock = yaml.safe_load((TOP / "dependencies.lock.yaml").read_text())

node = lock
for part in sys.argv[1].split("."):
    if not isinstance(node, dict) or part not in node:
        print(f"lock-get: キーが無い: {sys.argv[1]}", file=sys.stderr)
        sys.exit(1)
    node = node[part]

if isinstance(node, list):
    for e in node:
        print("\t".join(str(e[k]) for k in ("package", "version", "url", "sha256")))
else:
    print(node)
