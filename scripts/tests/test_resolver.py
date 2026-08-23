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

# digest の辻褄合わせにライブラリの純粋関数を使う (改ざんテスト用)
sys.path.insert(0, str(TOP / "scripts"))
import module_plan as resolver_mod  # noqa: E402


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
        """全 digest (artifact / tests / plan) の辻褄を合わせた改ざん plan を作る
        (digest 再検算を通過させ、containment 等の後段検証を直接テストするため)"""
        plan = json.loads(path.read_text())
        mutate(plan)
        resolver_mod.compute_digests(plan)
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

    def test_artifact_digest_tamper_detected(self):
        # packages を変更し digests.plan だけ更新 (artifact は旧値のまま) →
        # artifact の再検算で拒否される (sidecar 照合や cache key の偽装防止)
        _, path = self.plan()
        plan = json.loads(path.read_text())
        plan["modules"][0]["packages"]["apt"] = ["evil"]
        without = json.loads(json.dumps(plan))
        del without["digests"]["plan"]
        plan["digests"]["plan"] = resolver_mod.canonical_digest(without)
        path.write_text(json.dumps(plan, sort_keys=True, indent=2, ensure_ascii=False))
        r = self.verify(path)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("digests.artifact", r.stderr)

    def test_root_tamper_rejected(self):
        # source.root を scripts/ に差し替え、全 digest の辻褄を合わせても拒否
        _, path = self.plan()
        (self.ws / "scripts").mkdir(exist_ok=True)

        def mutate(plan):
            plan["modules"][0]["source"]["root"] = "scripts"

        self.tamper(path, mutate)
        r = self.verify(path)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("source.root が不正", r.stderr)

    def test_root_tamper_to_other_module_rejected(self):
        _, path = self.plan()

        def mutate(plan):
            plan["modules"][0]["source"]["root"] = "modules/beta"

        self.tamper(path, mutate)
        r = self.verify(path)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("source.root が不正", r.stderr)

    def test_required_secrets_tamper_rejected(self):
        # 注入先 (consumer) の付け替えを拒否 (secret isolation の維持)
        _, path = self.plan()

        def mutate(plan):
            plan["requiredSecrets"] = [
                {"name": "DEFAULT_PASSWORD", "consumer": "beta", "source": "environment"}
            ]

        self.tamper(path, mutate)
        r = self.verify(path)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("requiredSecrets", r.stderr)

    def test_modules_dir_symlink_rejected(self):
        # modules/ 自体を workspace 外への symlink に置換 → resolve も load も拒否
        _, path = self.plan()
        real = Path(self.tmp) / "outside-modules"
        shutil.move(str(self.ws / "modules"), str(real))
        os.symlink(real, self.ws / "modules")
        r, _ = resolve(self.ws)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("symlink", r.stderr)
        r = self.verify(path)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("symlink", r.stderr)

    def test_overlay_source_tamper_to_other_module_rejected(self):
        _, path = self.plan()

        def mutate(plan):
            alpha = next(m for m in plan["modules"] if m["id"] == "alpha")
            beta = next(m for m in plan["modules"] if m["id"] == "beta")
            alpha["overlays"][0]["source"] = "modules/beta/files"
            alpha["overlays"][0]["entries"] = beta["overlays"][0]["entries"]

        self.tamper(path, mutate)
        r = self.verify(path, "hooks")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("module root の外", r.stderr)

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


def add_configured_module(ws, *, defaults=None, schema_extra=None, secret=True):
    """configuration + secrets を宣言する module (gamma) を fixture に追加する"""
    d = ws / "modules" / "gamma"
    (d / "hooks").mkdir(parents=True)
    h = d / "hooks/setup.sh"
    h.write_text("#!/bin/sh\nexit 0\n")
    h.chmod(0o755)
    schema = {
        "type": "object",
        "additionalProperties": False,
        "required": ["name", "nested"],
        "properties": {
            "name": {"type": "string", "pattern": "^[a-z]+$"},
            "nested": {
                "type": "object",
                "additionalProperties": False,
                "properties": {
                    "a": {"type": "integer"},
                    "b": {"type": "integer"},
                },
            },
            "tags": {"type": "array", "items": {"type": "string"}},
        },
    }
    if schema_extra:
        schema["properties"].update(schema_extra)
    spec = {
        "apiVersion": "e54c.image/v1alpha1",
        "kind": "Module",
        "metadata": {"id": "gamma"},
        "configuration": {
            "schema": schema,
            "defaults": defaults
            if defaults is not None
            else {"name": "abc", "nested": {"a": 1, "b": 2}, "tags": ["x", "y"]},
        },
        "hooks": {"rootfs.customize": ["hooks/setup.sh"]},
    }
    if secret:
        spec["secrets"] = {"api-token": {"required": True, "description": "テスト"}}
    import yaml as _yaml

    (d / "module.yaml").write_text(_yaml.safe_dump(spec, allow_unicode=True))
    return d


def set_config_yaml(ws, module_config=None, secret_refs=None):
    lines = [
        "target:",
        "  board: radxa-e54c",
        "  architecture: arm64",
        "debian:",
        "  suite: trixie",
    ]
    import yaml as _yaml

    text = "\n".join(lines) + "\n"
    if module_config is not None:
        text += _yaml.safe_dump({"moduleConfiguration": module_config},
                                allow_unicode=True)
    if secret_refs is not None:
        text += _yaml.safe_dump({"secretReferences": secret_refs}, allow_unicode=True)
    (ws / "config.yaml").write_text(text)


GAMMA_REF = {"gamma": {"api-token": {"source": {"type": "environment",
                                                "name": "GAMMA_TOKEN"}}}}


class ConfigurationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.ws = make_workspace(self.tmp)
        add_configured_module(self.ws)
        set_config_yaml(self.ws, secret_refs=GAMMA_REF)

    def plan(self):
        r, path = resolve(self.ws)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(path.read_text()), path

    def gamma(self, plan):
        return next(m for m in plan["modules"] if m["id"] == "gamma")

    def test_defaults_only(self):
        plan, _ = self.plan()
        self.assertEqual(self.gamma(plan)["config"],
                         {"name": "abc", "nested": {"a": 1, "b": 2},
                          "tags": ["x", "y"]})

    def test_override_merge_and_replace(self):
        # object は再帰 merge (nested.a 保持)、scalar / array は置換
        set_config_yaml(self.ws,
                        module_config={"gamma": {"name": "xyz",
                                                 "nested": {"b": 9},
                                                 "tags": ["z"]}},
                        secret_refs=GAMMA_REF)
        plan, _ = self.plan()
        self.assertEqual(self.gamma(plan)["config"],
                         {"name": "xyz", "nested": {"a": 1, "b": 9}, "tags": ["z"]})

    def assert_fail(self, needle):
        r, _ = resolve(self.ws)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(needle, r.stderr)

    def test_unknown_module_in_configuration(self):
        set_config_yaml(self.ws, module_config={"nonexistent": {"x": 1}},
                        secret_refs=GAMMA_REF)
        self.assert_fail("選択されていない")

    def test_unknown_property_rejected(self):
        set_config_yaml(self.ws, module_config={"gamma": {"bogus": 1}},
                        secret_refs=GAMMA_REF)
        self.assert_fail("schema 違反")

    def test_type_violation_rejected(self):
        set_config_yaml(self.ws, module_config={"gamma": {"name": 5}},
                        secret_refs=GAMMA_REF)
        self.assert_fail("schema 違反")

    def test_pattern_violation_rejected(self):
        set_config_yaml(self.ws, module_config={"gamma": {"name": "ABC"}},
                        secret_refs=GAMMA_REF)
        self.assert_fail("schema 違反")

    def test_required_missing_rejected(self):
        # defaults から required の name を落とす → default も override も無い
        shutil.rmtree(self.ws / "modules/gamma")
        add_configured_module(self.ws, defaults={"nested": {"a": 1, "b": 2}})
        self.assert_fail("schema 違反")

    def test_defaults_schema_violation_rejected(self):
        shutil.rmtree(self.ws / "modules/gamma")
        add_configured_module(
            self.ws, defaults={"name": "ABC", "nested": {"a": 1, "b": 2}})
        self.assert_fail("schema 違反")

    def test_config_change_updates_artifact_not_tests(self):
        plan1, _ = self.plan()
        set_config_yaml(self.ws, module_config={"gamma": {"name": "xyz"}},
                        secret_refs=GAMMA_REF)
        plan2, _ = self.plan()
        self.assertNotEqual(plan1["digests"]["artifact"], plan2["digests"]["artifact"])
        self.assertNotEqual(plan1["digests"]["plan"], plan2["digests"]["plan"])
        self.assertEqual(plan1["digests"]["tests"], plan2["digests"]["tests"])

    def test_configuration_for_module_without_declaration(self):
        set_config_yaml(self.ws, module_config={"alpha": {"x": 1}},
                        secret_refs=GAMMA_REF)
        self.assert_fail("configuration を宣言していない")

    def test_inline_schema_ref_rejected(self):
        shutil.rmtree(self.ws / "modules/gamma")
        add_configured_module(self.ws, schema_extra={"evil": {"$ref": "#/x"}})
        self.assert_fail("未対応の schema keyword")

    def test_inline_schema_format_rejected(self):
        shutil.rmtree(self.ws / "modules/gamma")
        add_configured_module(self.ws, schema_extra={"mail": {"format": "email"}})
        self.assert_fail("未対応の schema keyword")

    def test_property_named_like_keyword_allowed(self):
        # properties 配下の property 名 "pattern" は keyword ではない
        shutil.rmtree(self.ws / "modules/gamma")
        add_configured_module(self.ws, schema_extra={"pattern": {"type": "string"}})
        r, _ = resolve(self.ws)
        self.assertEqual(r.returncode, 0, r.stderr)


class SecretReferenceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.ws = make_workspace(self.tmp)
        add_configured_module(self.ws)
        set_config_yaml(self.ws, secret_refs=GAMMA_REF)

    def plan(self):
        r, path = resolve(self.ws)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(path.read_text()), path

    def test_required_secrets_derived(self):
        plan, path = self.plan()
        self.assertEqual(plan["requiredSecrets"], [{
            "id": "api-token", "consumer": "gamma",
            "source": {"type": "environment", "name": "GAMMA_TOKEN"},
            "fileEnvironment": "E54C_SECRET_FILE_M5_GAMMA_S9_API_TOKEN",
        }])
        # secret 値 (環境変数の中身) が plan に現れない
        self.assertNotIn("secret-value", path.read_text())

    def test_resolve_does_not_read_secret_value(self):
        # GAMMA_TOKEN が未設定でも resolve は成功する (値は resolve 時に読まない)
        env = dict(os.environ)
        env.pop("GAMMA_TOKEN", None)
        r = subprocess.run(
            [sys.executable, str(RESOLVER), "--workspace", str(self.ws),
             "resolve", "--output", str(self.ws / "out/meta/module-plan.json")],
            capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_missing_required_reference_rejected(self):
        set_config_yaml(self.ws)  # secretReferences 無し
        r, _ = resolve(self.ws)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("必須 secret", r.stderr)

    def test_undeclared_reference_rejected(self):
        set_config_yaml(self.ws, secret_refs={
            **GAMMA_REF,
            "alpha": {"nope": {"source": {"type": "environment", "name": "X"}}}})
        r, _ = resolve(self.ws)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("宣言していない secret", r.stderr)

    def test_reference_to_unknown_module_rejected(self):
        set_config_yaml(self.ws, secret_refs={
            **GAMMA_REF,
            "ghost": {"tok": {"source": {"type": "environment", "name": "X"}}}})
        r, _ = resolve(self.ws)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("選択されていない", r.stderr)

    def test_secret_reference_change_updates_artifact(self):
        plan1, _ = self.plan()
        set_config_yaml(self.ws, secret_refs={
            "gamma": {"api-token": {"source": {"type": "environment",
                                               "name": "OTHER_VAR"}}}})
        plan2, _ = self.plan()
        self.assertNotEqual(plan1["digests"]["artifact"], plan2["digests"]["artifact"])

    def test_env_name_encoding_no_ambiguity(self):
        # a-b/c と a/b-c は長さプレフィクスで別名になる
        self.assertNotEqual(
            resolver_mod.secret_file_environment("a-b", "c"),
            resolver_mod.secret_file_environment("a", "b-c"))

    def test_alternate_username_plumbing(self):
        # harness が hard-coded username に依存しない配線の軽量検証:
        # default-user 相当の module に別 username を設定し、
        # module-config CLI が解決済み username を返すこと
        d = self.ws / "modules" / "default-user"
        (d / "hooks").mkdir(parents=True)
        import yaml as _yaml
        spec = {
            "apiVersion": "e54c.image/v1alpha1", "kind": "Module",
            "metadata": {"id": "default-user"},
            "configuration": {
                "schema": {"type": "object", "additionalProperties": False,
                           "required": ["username"],
                           "properties": {"username": {"type": "string"}}},
                "defaults": {"username": "debian"},
            },
        }
        (d / "module.yaml").write_text(_yaml.safe_dump(spec))
        set_config_yaml(self.ws,
                        module_config={"default-user": {"username": "student"}},
                        secret_refs=GAMMA_REF)
        _, path = self.plan()
        r = run(self.ws, "module-config", "--plan", str(path),
                "--module", "default-user")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)["username"], "student")


if __name__ == "__main__":
    unittest.main(verbosity=1)
