#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""resolve-modules.py の fixture テスト (Issue #14)。

実際の modules/ を書き換えず、一時ディレクトリに fixture workspace を構築して
determinism / digest 分離 / directory traversal / 改ざん plan の異常系を検証する。
標準ライブラリ (unittest) のみで動く。実行: make test-resolver
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOP = Path(__file__).resolve().parent.parent.parent
RESOLVER = TOP / "scripts" / "resolve-modules.py"


def make_workspace(tmp):
    """最小の fixture workspace (module 2 個) を構築する"""
    ws = Path(tmp) / "ws"
    (ws / "modules").mkdir(parents=True)
    (ws / "out/meta").mkdir(parents=True)
    (ws / "config.yaml").write_text(
        "target:\n  board: radxa-e54c\n  architecture: arm64\n"
        "debian:\n  suite: trixie\n"
    )

    def module(mid, *, desc="テスト", hook=True, test=True, overlay=True):
        d = ws / "modules" / mid
        (d / "hooks").mkdir(parents=True)
        (d / "tests").mkdir(parents=True)
        spec = [
            "apiVersion: e54c.image/v1alpha1",
            "kind: Module",
            "metadata:",
            f"  id: {mid}",
            f"  description: {desc}",
            "packages:",
            "  apt: [htop]",
        ]
        if overlay:
            (d / "files/etc" / mid).mkdir(parents=True)
            (d / "files/etc" / mid / "conf").write_text(f"{mid}\n")
            os.symlink("conf", d / "files/etc" / mid / "link")
            spec += ["overlays:", "  - source: files", "    target: /"]
        if hook:
            h = d / "hooks/setup.sh"
            h.write_text("#!/bin/sh\nexit 0\n")
            h.chmod(0o755)
            spec += ["hooks:", "  rootfs.customize:", "    - hooks/setup.sh"]
        if test:
            t = d / "tests/rootfs.sh"
            t.write_text("#!/bin/sh\nexit 0\n")
            t.chmod(0o755)
            spec += ["tests:", "  rootfs:", "    - tests/rootfs.sh"]
        (d / "module.yaml").write_text("\n".join(spec) + "\n")
        return d

    module("alpha")
    module("beta")
    return ws


def run(ws, *args, check=False):
    return subprocess.run(
        [sys.executable, str(RESOLVER), "--workspace", str(ws), *args],
        capture_output=True, text=True, check=check,
    )


def resolve(ws, output="out/meta/module-plan.json"):
    r = run(ws, "resolve", "--output", str(ws / output))
    return r, (ws / output)


class ResolverTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.ws = make_workspace(self.tmp)

    def plan(self):
        r, path = resolve(self.ws)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(path.read_text()), path

    # --- determinism / digest ---

    def test_byte_identical(self):
        _, p1 = resolve(self.ws)
        b1 = p1.read_bytes()
        _, p2 = resolve(self.ws)
        self.assertEqual(b1, p2.read_bytes())

    def test_no_absolute_paths_or_tmp(self):
        plan, path = self.plan()
        text = path.read_text()
        self.assertNotIn(str(self.ws), text)  # workspace absolute path
        self.assertNotIn(self.tmp, text)
        for m in plan["modules"]:
            self.assertFalse(m["source"]["root"].startswith("/"))

    def test_order_stable(self):
        plan, _ = self.plan()
        self.assertEqual([m["id"] for m in plan["modules"]], ["alpha", "beta"])

    def test_hook_change_updates_artifact_digest(self):
        plan1, _ = self.plan()
        (self.ws / "modules/alpha/hooks/setup.sh").write_text("#!/bin/sh\nexit 1\n")
        plan2, _ = self.plan()
        self.assertNotEqual(plan1["digests"]["artifact"], plan2["digests"]["artifact"])

    def test_overlay_change_updates_artifact_digest(self):
        plan1, _ = self.plan()
        (self.ws / "modules/alpha/files/etc/alpha/conf").write_text("changed\n")
        plan2, _ = self.plan()
        self.assertNotEqual(plan1["digests"]["artifact"], plan2["digests"]["artifact"])

    def test_test_change_updates_only_test_digest(self):
        plan1, _ = self.plan()
        (self.ws / "modules/alpha/tests/rootfs.sh").write_text("#!/bin/sh\nexit 2\n")
        plan2, _ = self.plan()
        self.assertEqual(plan1["digests"]["artifact"], plan2["digests"]["artifact"])
        self.assertNotEqual(plan1["digests"]["tests"], plan2["digests"]["tests"])
        self.assertNotEqual(plan1["digests"]["plan"], plan2["digests"]["plan"])

    def test_description_change_keeps_artifact_digest(self):
        plan1, _ = self.plan()
        yml = self.ws / "modules/alpha/module.yaml"
        yml.write_text(yml.read_text().replace("description: テスト", "description: 変更"))
        plan2, _ = self.plan()
        self.assertEqual(plan1["digests"]["artifact"], plan2["digests"]["artifact"])
        self.assertNotEqual(plan1["digests"]["plan"], plan2["digests"]["plan"])

    def test_mode_change_detected(self):
        plan1, _ = self.plan()
        (self.ws / "modules/alpha/hooks/setup.sh").chmod(0o700)
        plan2, _ = self.plan()
        self.assertNotEqual(plan1["digests"]["artifact"], plan2["digests"]["artifact"])

    def test_symlink_target_in_digest_not_followed(self):
        plan, _ = self.plan()
        alpha = next(m for m in plan["modules"] if m["id"] == "alpha")
        entries = {e["path"]: e for e in alpha["overlays"][0]["entries"]}
        self.assertEqual(entries["etc/alpha/link"]["type"], "symlink")
        self.assertEqual(entries["etc/alpha/link"]["linkTarget"], "conf")
        self.assertNotIn("sha256", entries["etc/alpha/link"])

    def test_required_secrets_only_for_builtin_consumers(self):
        plan, _ = self.plan()
        self.assertEqual(plan["requiredSecrets"], [])

    # --- traversal / 不正 manifest ---

    def assert_resolve_fails(self, needle):
        r, _ = resolve(self.ws)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(needle, r.stderr)

    def edit_manifest(self, mid, old, new):
        yml = self.ws / "modules" / mid / "module.yaml"
        yml.write_text(yml.read_text().replace(old, new))

    def test_hook_parent_traversal(self):
        self.edit_manifest("alpha", "hooks/setup.sh", "../outside.sh")
        (self.ws / "modules/outside.sh").write_text("#!/bin/sh\n")
        self.assert_resolve_fails("schema 違反")

    def test_hook_inner_traversal(self):
        self.edit_manifest("alpha", "hooks/setup.sh", "hooks/../../beta/hooks/setup.sh")
        self.assert_resolve_fails("schema 違反")

    def test_hook_absolute_path(self):
        self.edit_manifest("alpha", "hooks/setup.sh", "/etc/passwd")
        self.assert_resolve_fails("schema 違反")

    def test_module_id_with_slash(self):
        self.edit_manifest("alpha", "id: alpha", "id: alpha/evil")
        self.assert_resolve_fails("schema 違反")

    def test_module_id_mismatch(self):
        self.edit_manifest("alpha", "id: alpha", "id: gamma")
        self.assert_resolve_fails("一致しない")

    def test_hook_is_symlink(self):
        h = self.ws / "modules/alpha/hooks/setup.sh"
        h.unlink()
        os.symlink("../../beta/hooks/setup.sh", h)
        self.assert_resolve_fails("symlink")

    def test_hook_parent_dir_is_symlink(self):
        d = self.ws / "modules/alpha/hooks"
        real = self.ws / "modules/alpha/realhooks"
        d.rename(real)
        os.symlink("realhooks", d)
        self.assert_resolve_fails("symlink")

    def test_overlay_source_is_symlink(self):
        d = self.ws / "modules/alpha/files"
        real = self.ws / "outside-files"
        shutil.move(str(d), str(real))
        os.symlink(real, d)
        self.assert_resolve_fails("ディレクトリとして存在しない")

    def test_dangling_symlink_in_overlay_kept(self):
        os.symlink("/nonexistent", self.ws / "modules/alpha/files/etc/alpha/dangling")
        plan, _ = self.plan()  # dangling symlink は保持され、解決は成功する
        alpha = next(m for m in plan["modules"] if m["id"] == "alpha")
        entries = {e["path"]: e for e in alpha["overlays"][0]["entries"]}
        self.assertEqual(entries["etc/alpha/dangling"]["type"], "symlink")

    def test_hook_not_executable(self):
        (self.ws / "modules/alpha/hooks/setup.sh").chmod(0o644)
        self.assert_resolve_fails("実行ビット")

    def test_overlay_conflict(self):
        # beta が alpha と同じパスを配置する
        d = self.ws / "modules/beta/files/etc/alpha"
        d.mkdir(parents=True)
        (d / "conf").write_text("conflict\n")
        self.assert_resolve_fails("overlay 競合")

    # --- 改ざん plan / stale ---

    def verify(self, path, phase="all"):
        return run(self.ws, "verify-inputs", "--plan", str(path), "--phase", phase)

    def tamper(self, path, mutate):
        plan = json.loads(path.read_text())
        mutate(plan)
        # digests.plan を再計算して「schema/自己整合は通る」改ざん plan を作る
        import hashlib
        without = json.loads(json.dumps(plan))
        del without["digests"]["plan"]
        data = json.dumps(without, sort_keys=True, separators=(",", ":"),
                          ensure_ascii=False).encode()
        plan["digests"]["plan"] = "sha256:" + hashlib.sha256(data).hexdigest()
        path.write_text(json.dumps(plan, sort_keys=True, indent=2, ensure_ascii=False))

    def test_verify_ok(self):
        _, path = self.plan()[1], self.plan()[1]
        r = self.verify(path)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_plan_digest_tamper_detected(self):
        _, path = self.plan()
        plan = json.loads(path.read_text())
        plan["modules"][0]["packages"]["apt"] = ["evil"]
        path.write_text(json.dumps(plan, sort_keys=True, indent=2, ensure_ascii=False))
        r = self.verify(path)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("digests.plan", r.stderr)

    def test_plan_path_to_other_module_rejected(self):
        _, path = self.plan()

        def mutate(plan):
            alpha = next(m for m in plan["modules"] if m["id"] == "alpha")
            beta_hook = "modules/beta/hooks/setup.sh"
            alpha["hooks"]["rootfs.customize"][0]["path"] = beta_hook

        self.tamper(path, mutate)
        r = self.verify(path)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("module root の外", r.stderr)

    def test_plan_path_to_core_script_rejected(self):
        _, path = self.plan()
        (self.ws / "scripts").mkdir(exist_ok=True)
        core = self.ws / "scripts/build.sh"
        core.write_text("#!/bin/sh\n")
        core.chmod(0o755)

        def mutate(plan):
            alpha = next(m for m in plan["modules"] if m["id"] == "alpha")
            alpha["hooks"]["rootfs.customize"][0]["path"] = "scripts/build.sh"

        self.tamper(path, mutate)
        r = self.verify(path)
        self.assertNotEqual(r.returncode, 0)

    def test_stale_hook_content(self):
        _, path = self.plan()
        (self.ws / "modules/alpha/hooks/setup.sh").write_text("#!/bin/sh\nexit 9\n")
        r = self.verify(path, "hooks")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("module plan is stale", r.stderr)
        self.assertIn("make resolve", r.stderr)

    def test_stale_file_replaced_by_symlink(self):
        _, path = self.plan()
        h = self.ws / "modules/alpha/hooks/setup.sh"
        content = h.read_text()
        h.unlink()
        (self.ws / "modules/alpha/hooks/real.sh").write_text(content)
        os.symlink("real.sh", h)
        r = self.verify(path, "hooks")
        self.assertNotEqual(r.returncode, 0)

    def test_stale_mode_change(self):
        _, path = self.plan()
        (self.ws / "modules/alpha/hooks/setup.sh").chmod(0o700)
        r = self.verify(path, "hooks")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("mode", r.stderr)

    def test_stale_test_only_does_not_block_hooks_phase(self):
        _, path = self.plan()
        (self.ws / "modules/alpha/tests/rootfs.sh").write_text("#!/bin/sh\nexit 3\n")
        # hooks phase の検証は test の変更に影響されない (test-only 変更で
        # rootfs を再利用できる分離の裏付け)
        self.assertEqual(self.verify(path, "hooks").returncode, 0)
        self.assertNotEqual(self.verify(path, "tests.rootfs").returncode, 0)

    # --- sidecar ---

    def test_sidecar_roundtrip_and_mismatch(self):
        _, path = self.plan()
        tar = self.ws / "rootfs.tar"
        tar.write_bytes(b"fake-rootfs")
        sidecar = self.ws / "rootfs.meta.json"
        r = run(self.ws, "write-sidecar", "--plan", str(path),
                "--rootfs", str(tar), "--output", str(sidecar))
        self.assertEqual(r.returncode, 0, r.stderr)
        r = run(self.ws, "verify-sidecar", "--plan", str(path),
                "--rootfs", str(tar), "--sidecar", str(sidecar))
        self.assertEqual(r.returncode, 0, r.stderr)
        # tar 実体の改ざん
        tar.write_bytes(b"tampered")
        r = run(self.ws, "verify-sidecar", "--plan", str(path),
                "--rootfs", str(tar), "--sidecar", str(sidecar))
        self.assertNotEqual(r.returncode, 0)
        # module 入力が変わった plan とは不一致
        tar.write_bytes(b"fake-rootfs")
        (self.ws / "modules/alpha/hooks/setup.sh").write_text("#!/bin/sh\nexit 5\n")
        _, path2 = self.plan()
        r = run(self.ws, "verify-sidecar", "--plan", str(path2),
                "--rootfs", str(tar), "--sidecar", str(sidecar))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("再構築", r.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=1)
