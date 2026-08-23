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

# schema 1 で radxa.debs に必ず含まれるべきパッケージ。
# エントリの丸ごと削除 (メタパッケージだけ消える等) は個別フィールド検証を
# すり抜けるため、集合として要求する
RADXA_REQUIRED = {"radxa-archive-keyring", "u-boot-rk2601", "u-boot-radxa-e54c"}


def die(msg):
    print(f"lock-get: {msg}", file=sys.stderr)
    sys.exit(1)


def check_artifact(name, node):
    """version/url/sha256 を持つ artifact 節の共通検証"""
    if not isinstance(node, dict):
        die(f"{name} が dict でない")
    for k in ("version", "url", "sha256"):
        v = str(node.get(k, ""))
        if not v.strip():
            die(f"{name}.{k} が空")
        if re.search(r"[\t\n\r]", v):
            die(f"{name}.{k} に制御文字 (タブ/改行) が含まれる")
    if not re.fullmatch(r"[0-9a-f]{64}", node["sha256"]):
        die(f"{name}.sha256 の書式が不正 (64 桁の hex であること)")
    if not node["url"].startswith("https://"):
        die(f"{name}.url が https でない")


def validate_lock(lock):
    """どのキーを取得する場合でも、lock 全体の整合性を先に検証する"""
    if lock.get("schema") != 1:
        die(f"未対応の schema: {lock.get('schema')!r} (期待: 1)")
    debian = lock.get("debian") or {}
    for k in ("snapshot", "security_snapshot"):
        if not re.fullmatch(r"\d{8}T\d{6}Z", str(debian.get(k, ""))):
            die(f"debian.{k} の書式が不正 (例: 20260821T205528Z)")
    base_image = str((lock.get("devcontainer") or {}).get("base_image", ""))
    if not re.search(r"@sha256:[0-9a-f]{64}$", base_image):
        die("devcontainer.base_image が digest (@sha256:...) で固定されていない")
    check_artifact("kernel", lock.get("kernel"))
    check_artifact("k3s", lock.get("k3s"))
    debs = (lock.get("radxa") or {}).get("debs")
    if not isinstance(debs, list) or not debs:
        die("radxa.debs が空")
    seen = set()
    for e in debs:
        pkg = str(e.get("package", "?"))
        for k in ("package", "version", "url", "sha256"):
            v = str(e.get(k, ""))
            if not v.strip():
                die(f"radxa.debs: {pkg} の {k} が空")
            if re.search(r"[\t\n\r]", v):
                die(f"radxa.debs: {pkg} の {k} に制御文字が含まれる")
        if not re.fullmatch(r"[0-9a-f]{64}", e["sha256"]):
            die(f"radxa.debs: {pkg} の sha256 の書式が不正")
        if not e["url"].startswith("https://"):
            die(f"radxa.debs: {pkg} の url が https でない")
        if pkg in seen:
            die(f"radxa.debs: package が重複: {pkg}")
        seen.add(pkg)
    missing = RADXA_REQUIRED - seen
    if missing:
        die(f"radxa.debs に必須パッケージが無い: {', '.join(sorted(missing))}")


lock = yaml.safe_load((TOP / "dependencies.lock.yaml").read_text())
validate_lock(lock)

node = lock
for part in sys.argv[1].split("."):
    if not isinstance(node, dict) or part not in node:
        die(f"キーが無い: {sys.argv[1]}")
    node = node[part]

if isinstance(node, list):
    for e in node:
        print("\t".join(str(e[k]) for k in ("package", "version", "url", "sha256")))
else:
    print(node)
