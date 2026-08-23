#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""modules/*/module.yaml を辞書順に探索・検証して解決結果を出力する (Issue #7 MVP)。

- 全組み込みモジュールを自動的に有効化する (profile / enable 条件は未実装)
- 検証はすべて build 開始前の fail-fast:
    * apiVersion / kind / metadata.id (ディレクトリ名と一致、重複禁止)
    * lifecycle phase: 対応 phase 以外は「予約 (未対応)」も含めて明示的に失敗
    * overlays: MVP では target "/" 固定。source はモジュール内のディレクトリ
    * hooks / tests: モジュール内の通常ファイル (symlink 不可) + 実行ビット必須
    * overlay 競合: core files/ と全モジュール overlay の間で、同一の
      非ディレクトリパスへの配置を拒否 (ディレクトリの共有は許可)
- 出力: JSON (--json、render-bdebstrap.py 等が消費) または
  resolved-modules.yaml (--resolved <path>、provenance 用)
"""
import argparse
import json
import sys
from pathlib import Path

import yaml

TOP = Path(__file__).resolve().parent.parent
MODULES_DIR = TOP / "modules"

API_VERSION = "e54c.image/v1alpha1"
KIND = "Module"

# MVP で実行可能な phase と、スキーマ予約のみ (指定されたら明示的に失敗) の phase
SUPPORTED_HOOK_PHASES = {"rootfs.customize", "rootfs.seal"}
RESERVED_HOOK_PHASES = {"image.finalize", "runtime.firstBoot"}
SUPPORTED_TEST_PHASES = {"rootfs", "boot"}
RESERVED_TEST_PHASES = {"hardware"}


def die(msg):
    print(f"resolve-modules: エラー: {msg}", file=sys.stderr)
    sys.exit(1)


def check_module_file(mod_dir, rel, what):
    """モジュール内の実行ファイル参照を検証し、絶対パスを返す"""
    if Path(rel).is_absolute() or ".." in Path(rel).parts:
        die(f"{mod_dir.name}: {what} '{rel}' は相対パスでモジュール内を指すこと")
    p = mod_dir / rel
    # symlink による脱出を防ぐため、実体解決後もモジュール内に収まることを要求する
    if p.is_symlink():
        die(f"{mod_dir.name}: {what} '{rel}' が symlink (禁止)")
    if not p.is_file():
        die(f"{mod_dir.name}: {what} '{rel}' が通常ファイルとして存在しない")
    if not p.resolve().is_relative_to(mod_dir.resolve()):
        die(f"{mod_dir.name}: {what} '{rel}' がモジュール外を指している")
    import os

    if not os.access(p, os.X_OK):
        die(f"{mod_dir.name}: {what} '{rel}' に実行ビットが無い (chmod +x すること)")
    return p


def overlay_entries(root):
    """overlay ツリー内の全エントリを (相対パス → 種別) で返す。symlink 脱出も検証"""
    entries = {}
    for p in sorted(root.rglob("*")):
        rel = p.relative_to(root)
        if p.is_symlink():
            # symlink 自体の配置は許可するが、モジュール/ツリー外への解決は拒否しない
            # (rootfs 内で解決されるリンクであり、ビルダー上の実体参照ではないため)。
            # ただし競合検出上は非ディレクトリとして扱う
            entries[str(rel)] = "file"
        elif p.is_dir():
            entries[str(rel)] = "dir"
        else:
            entries[str(rel)] = "file"
    return entries


def resolve():
    modules = []
    seen_ids = set()
    if MODULES_DIR.is_dir():
        mod_dirs = sorted(d for d in MODULES_DIR.iterdir() if d.is_dir())
    else:
        mod_dirs = []
    for mod_dir in mod_dirs:
        if mod_dir.is_symlink():
            die(f"{mod_dir.name}: モジュールディレクトリが symlink (禁止)")
        yml = mod_dir / "module.yaml"
        if not yml.is_file():
            die(f"{mod_dir.name}: module.yaml が無い")
        try:
            spec = yaml.safe_load(yml.read_text())
        except yaml.YAMLError as e:
            die(f"{mod_dir.name}/module.yaml: YAML が不正: {e}")
        if not isinstance(spec, dict):
            die(f"{mod_dir.name}/module.yaml: dict でない")
        if spec.get("apiVersion") != API_VERSION:
            die(f"{mod_dir.name}: apiVersion が不正 (期待: {API_VERSION})")
        if spec.get("kind") != KIND:
            die(f"{mod_dir.name}: kind が不正 (期待: {KIND})")
        mid = (spec.get("metadata") or {}).get("id")
        if mid != mod_dir.name:
            die(f"{mod_dir.name}: metadata.id ({mid!r}) がディレクトリ名と一致しない")
        if mid in seen_ids:
            die(f"module ID が重複: {mid}")
        seen_ids.add(mid)

        # --- packages ---
        pkgs = (spec.get("packages") or {}).get("apt") or []
        if not isinstance(pkgs, list) or not all(isinstance(p, str) and p for p in pkgs):
            die(f"{mid}: packages.apt は文字列のリストであること")

        # --- overlays (MVP: target は "/" 固定) ---
        overlays = []
        for ov in spec.get("overlays") or []:
            src = ov.get("source")
            target = ov.get("target", "/")
            if target != "/":
                die(f"{mid}: overlays.target は MVP では '/' のみ対応 (指定: {target!r})")
            if not src or Path(src).is_absolute() or ".." in Path(src).parts:
                die(f"{mid}: overlays.source '{src}' は相対パスでモジュール内を指すこと")
            src_dir = mod_dir / src
            if src_dir.is_symlink() or not src_dir.is_dir():
                die(f"{mid}: overlays.source '{src}' がディレクトリとして存在しない")
            # 中間コンポーネントの symlink による脱出も拒否する
            # (src_dir 自体が symlink でなくても、親が module 外を指し得る)
            if not src_dir.resolve().is_relative_to(mod_dir.resolve()):
                die(f"{mid}: overlays.source '{src}' がモジュール外を指している")
            overlays.append(str(src_dir))

        # --- hooks ---
        hooks = {}
        for phase, scripts in (spec.get("hooks") or {}).items():
            if phase in RESERVED_HOOK_PHASES:
                die(f"{mid}: hook phase '{phase}' はスキーマ予約のみで未対応")
            if phase not in SUPPORTED_HOOK_PHASES:
                die(f"{mid}: 未知の hook phase '{phase}'")
            if not isinstance(scripts, list):
                die(f"{mid}: hooks.{phase} はリストであること")
            hooks[phase] = [
                str(check_module_file(mod_dir, s, f"hooks.{phase}")) for s in scripts
            ]

        # --- tests ---
        tests = {}
        for phase, scripts in (spec.get("tests") or {}).items():
            if phase in RESERVED_TEST_PHASES:
                die(f"{mid}: test phase '{phase}' はスキーマ予約のみで未対応")
            if phase not in SUPPORTED_TEST_PHASES:
                die(f"{mid}: 未知の test phase '{phase}'")
            if not isinstance(scripts, list):
                die(f"{mid}: tests.{phase} はリストであること")
            tests[phase] = [
                str(check_module_file(mod_dir, s, f"tests.{phase}")) for s in scripts
            ]

        modules.append(
            {
                "id": mid,
                "path": str(mod_dir.relative_to(TOP)),
                "packages": pkgs,
                "overlays": overlays,
                "hooks": hooks,
                "tests": tests,
            }
        )

    # --- overlay 競合検出 (core files/ + 全モジュール) ---
    trees = []
    core_files = TOP / "files"
    if core_files.is_dir():
        trees.append(("core", core_files))
    for m in modules:
        for ov in m["overlays"]:
            trees.append((f"module[{m['id']}]", Path(ov)))
    placed = {}  # 相対パス → (owner, 種別)
    for owner, root in trees:
        for rel, kind in overlay_entries(root).items():
            if rel in placed:
                prev_owner, prev_kind = placed[rel]
                if prev_kind == "dir" and kind == "dir":
                    continue  # ディレクトリの共有は許可
                die(
                    f"overlay 競合: /{rel} を {prev_owner} と {owner} の両方が配置している"
                )
            placed[rel] = (owner, kind)

    return modules


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true", help="解決結果を JSON で stdout に出力")
    ap.add_argument("--resolved", metavar="PATH", help="resolved-modules.yaml を書き出す")
    args = ap.parse_args()

    modules = resolve()
    order = ", ".join(m["id"] for m in modules) or "(なし)"
    print(f"resolve-modules: {len(modules)} 個のモジュールを解決 (実行順: {order})",
          file=sys.stderr)

    if args.json:
        json.dump(modules, sys.stdout, ensure_ascii=False, indent=1)
        print()
    if args.resolved:
        out = {
            "apiVersion": API_VERSION,
            "modules": [
                {"id": m["id"], "source": "builtin", "path": m["path"]} for m in modules
            ],
        }
        Path(args.resolved).parent.mkdir(parents=True, exist_ok=True)
        Path(args.resolved).write_text(yaml.safe_dump(out, sort_keys=False, allow_unicode=True))


if __name__ == "__main__":
    main()
