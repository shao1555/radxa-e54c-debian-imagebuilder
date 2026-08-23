#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""canonical ModulePlan の resolver / 検証ライブラリ (Issue #14)。

CLI は scripts/resolve-modules.py。consumer (render-bdebstrap.py 等) はこの
モジュールを import し、plan の load (検証込み) と入力の再検証を自プロセス内で
行ってから使う。

あるビルドで「何を・どの順序で・どの入力から実行するか」を一度だけ解決し、
out/meta/module-plan.json として build / test / Release 全体で共有する。
consumer は modules/ を再探索せず、plan に記録された入力だけを利用し、
利用直前に containment / type / mode / digest を再検証する
(「Resolver が生成した plan だから安全」とは仮定しない)。

Resolution Pipeline (将来 profile / configuration / dependencies を差し込める順序):
  1. BuildRequest を読み込む (現在は config.yaml からの暗黙値)
  2. module source を発見する
  3. manifest の構造 (JSON Schema)・identity を検証する
  4. module を選択する (現在: all-builtin)
  5. configuration を解決する (現在: 空)
  6. dependencies / capabilities / conflicts を解決する (現在: 空)
  7. 選択済み module の filesystem input を検証する
  8. overlay 競合など cross-module 制約を検証する
  9. 決定的な実行順を求める (現在: module ID の辞書順)
  10. content digest を計算する (artifact / tests / plan の 3 種)
  11. ModulePlan を atomic write する

determinism: 同じ入力から byte-identical な plan を生成する。plan には
absolute path / timestamp / hostname / PID / 一時パス / secret 値を含めない。
"""
import argparse
import hashlib
import json
import os
import stat
import sys
import tempfile
from pathlib import Path, PurePosixPath

import jsonschema
import yaml

DEFAULT_WORKSPACE = Path(__file__).resolve().parent.parent
API_VERSION = "e54c.image/v1alpha1"

SUPPORTED_HOOK_PHASES = ("rootfs.customize", "rootfs.seal")
RESERVED_HOOK_PHASES = ("image.finalize", "runtime.firstBoot")
SUPPORTED_TEST_PHASES = ("rootfs", "boot")
RESERVED_TEST_PHASES = ("hardware",)

# module manifest の inline configuration schema で MVP が許可する keyword
# (allowlist。禁止列挙より安全。外部参照・別 resource 評価につながるものは
#  すべて拒否され、format も MVP では拒否する: 黙って無視すると module 作者が
#  検証済みだと誤解するため)
SCHEMA_ALLOWED_KEYWORDS = {
    "type", "properties", "required", "additionalProperties", "items",
    "enum", "const", "pattern", "minLength", "maxLength",
    "minimum", "maximum", "minItems", "maxItems", "uniqueItems",
    "description", "title",
}
ID_RE = r"^[a-z][a-z0-9-]{0,62}$"


def encode_env_component(s):
    return s.upper().replace("-", "_")


def secret_file_environment(module_id, secret_id):
    """secret ファイルパスを渡す環境変数名。長さプレフィクスで境界を一意にする
    (単純な <MODULE>_<SECRET> 連結は a-b/c と a/b-c が衝突する)"""
    return (
        f"E54C_SECRET_FILE_M{len(module_id)}_{encode_env_component(module_id)}"
        f"_S{len(secret_id)}_{encode_env_component(secret_id)}"
    )


class ResolveError(Exception):
    pass


def die(msg):
    print(f"resolve-modules: エラー: {msg}", file=sys.stderr)
    sys.exit(1)


def info(msg):
    print(f"resolve-modules: {msg}", file=sys.stderr)


# --- 共通 helper -------------------------------------------------------------

def sha256_bytes(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return "sha256:" + h.hexdigest()


def canonical_digest(obj):
    """digest 計算用の canonical serialize (key sort・固定 separator・UTF-8)"""
    data = json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return sha256_bytes(data.encode("utf-8"))


def mode_str(st_mode):
    return format(stat.S_IMODE(st_mode), "04o")


def check_rel_string(rel, what):
    """path 文字列そのものの検証 (実体は見ない)"""
    if not rel or "\x00" in rel or "\r" in rel or "\n" in rel:
        raise ResolveError(f"{what}: path に NUL/CR/LF を含む、または空")
    p = PurePosixPath(rel)
    if p.is_absolute():
        raise ResolveError(f"{what}: absolute path は不可: {rel}")
    if any(part in (".", "..") for part in p.parts):
        raise ResolveError(f"{what}: '.' / '..' component は不可: {rel}")


def check_no_symlink_components(root, rel, what):
    """root から rel までの各 component を lstat し、symlink が無いことを確認"""
    cur = root
    for part in PurePosixPath(rel).parts:
        cur = cur / part
        if cur.is_symlink():
            raise ResolveError(f"{what}: 経路に symlink を含む: {cur}")


def check_containment(root, rel, what):
    """実体解決後の containment (文字列 prefix に依存しない)"""
    root_r = root.resolve(strict=True)
    try:
        candidate = (root / rel).resolve(strict=True)
    except OSError as e:
        raise ResolveError(f"{what}: 実体を解決できない: {rel} ({e})") from e
    if not candidate.is_relative_to(root_r):
        raise ResolveError(f"{what}: module root の外を指している: {rel}")
    return candidate


def load_schema(workspace, name):
    # schema は常にこのリポジトリ (実装と同梱) のものを使う
    schema_dir = Path(__file__).resolve().parent.parent / "schemas"
    return json.loads((schema_dir / name).read_text())


def schema_validate(instance, schema, what):
    validator = jsonschema.Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(instance), key=lambda e: list(e.path))
    if errors:
        e = errors[0]
        loc = "/".join(str(p) for p in e.path) or "(root)"
        raise ResolveError(f"{what}: schema 違反 at {loc}: {e.message}")


# --- Resolution Pipeline -----------------------------------------------------

def load_build_request(workspace):
    """1. BuildRequest。config.yaml adapter が機械的に生成する (module 固有の
    既定値や secret 宣言はハードコードしない。将来は profile parser も同じ
    形式を生成し、Resolver 入口で同じ schema 検証を受ける)"""
    cfg = yaml.safe_load((workspace / "config.yaml").read_text())
    target = cfg.get("target") or {}
    board = target.get("board")
    arch = target.get("architecture")
    suite = (cfg.get("debian") or {}).get("suite")
    if not board or not arch or not suite:
        raise ResolveError(
            "config.yaml に target.board / target.architecture / debian.suite が必要"
        )
    request = {
        "target": {"board": board, "architecture": arch, "suite": suite},
        "selection": {"mode": "all-builtin"},
        "moduleConfiguration": cfg.get("moduleConfiguration") or {},
        "secretReferences": cfg.get("secretReferences") or {},
    }
    schema_validate(
        request, load_schema(workspace, "build-request.schema.json"), "BuildRequest"
    )
    return request


def check_inline_schema(schema, what, path="configuration.schema"):
    """module manifest の inline JSON Schema の安全性検証。
    許可 keyword の allowlist (SCHEMA_ALLOWED_KEYWORDS) 方式で、外部参照や
    別 resource 評価につながる keyword・未知の keyword を拒否する。
    properties 配下の property 名は schema keyword として誤判定しない"""
    if not isinstance(schema, dict):
        raise ResolveError(f"{what}: {path} は object であること")
    for key, value in schema.items():
        if key not in SCHEMA_ALLOWED_KEYWORDS:
            raise ResolveError(
                f"{what}: {path} に未対応の schema keyword: {key!r} "
                "(MVP の allowlist 外。format も含め必要になった時点で明示追加する)"
            )
        if key == "properties":
            if not isinstance(value, dict):
                raise ResolveError(f"{what}: {path}.properties は object であること")
            for prop, sub in value.items():
                # property 名は keyword ではないため検査対象にしない
                check_inline_schema(sub, what, f"{path}.properties.{prop}")
        elif key == "items":
            check_inline_schema(value, what, f"{path}.items")
        elif key == "additionalProperties":
            if isinstance(value, dict):
                check_inline_schema(value, what, f"{path}.additionalProperties")
    return schema


def load_module_configuration(spec, mid):
    """manifest の configuration 節の検証 (schema 安全性 + defaults の適合)"""
    conf = spec.get("configuration")
    if conf is None:
        return None
    schema = conf["schema"]
    check_inline_schema(schema, mid)
    if schema.get("type") != "object":
        raise ResolveError(f"{mid}: configuration.schema の root は type: object であること")
    if schema.get("additionalProperties") is not False:
        raise ResolveError(
            f"{mid}: configuration.schema は additionalProperties: false 必須"
        )
    try:
        jsonschema.Draft202012Validator.check_schema(schema)
    except jsonschema.SchemaError as e:
        raise ResolveError(f"{mid}: configuration.schema が不正: {e.message}") from e
    # defaults 自体も同じ schema で検証する (required の充足は解決後に検査
    # するため、ここでは required を除いた schema で形だけ検証する)
    shape_only = {k: v for k, v in schema.items() if k != "required"}
    schema_validate(conf["defaults"], shape_only, f"{mid}: configuration.defaults")
    return {"schema": schema, "defaults": conf["defaults"]}


def merge_configuration(defaults, override, path="moduleConfiguration"):
    """決定的な recursive merge。object 同士は再帰、scalar / array は
    override が置換。null は schema が許すときだけ通常の値 (削除の意味にしない)"""
    if isinstance(defaults, dict) and isinstance(override, dict):
        merged = dict(defaults)
        for k, v in override.items():
            if k in merged:
                merged[k] = merge_configuration(merged[k], v, f"{path}.{k}")
            else:
                merged[k] = v
        return merged
    return override


def check_modules_root(workspace):
    """modules/ ディレクトリ自体の検証 (トップレベル symlink による
    workspace 外 module の混入を拒否する)"""
    modules_dir = workspace / "modules"
    if modules_dir.is_symlink():
        raise ResolveError("modules/ 自体が symlink (禁止)")
    if modules_dir.is_dir():
        if not modules_dir.resolve(strict=True).is_relative_to(
            workspace.resolve(strict=True)
        ):
            raise ResolveError("modules/ が workspace の外を指している")
    return modules_dir


def discover_modules(workspace):
    """2. module source の発見"""
    modules_dir = check_modules_root(workspace)
    if not modules_dir.is_dir():
        return []
    dirs = []
    for d in sorted(modules_dir.iterdir()):
        if d.is_symlink():
            raise ResolveError(f"{d.name}: モジュールディレクトリが symlink (禁止)")
        if d.is_dir():
            dirs.append(d)
    return dirs


def load_manifest(workspace, mod_dir, module_schema):
    """3. manifest の構造・identity 検証"""
    yml = mod_dir / "module.yaml"
    if yml.is_symlink() or not yml.is_file():
        raise ResolveError(f"{mod_dir.name}: module.yaml が通常ファイルとして存在しない")
    try:
        spec = yaml.safe_load(yml.read_text())
    except yaml.YAMLError as e:
        raise ResolveError(f"{mod_dir.name}/module.yaml: YAML が不正: {e}") from e
    schema_validate(spec, module_schema, f"{mod_dir.name}/module.yaml")
    mid = spec["metadata"]["id"]
    if mid != mod_dir.name:
        raise ResolveError(
            f"{mod_dir.name}: metadata.id ({mid!r}) がディレクトリ名と一致しない"
        )
    # 予約 phase は schema 上は書けるが、内容があれば「未対応」として明示的に失敗
    for phase in RESERVED_HOOK_PHASES:
        if (spec.get("hooks") or {}).get(phase):
            raise ResolveError(f"{mid}: hook phase '{phase}' はスキーマ予約のみで未対応")
    for phase in RESERVED_TEST_PHASES:
        if (spec.get("tests") or {}).get(phase):
            raise ResolveError(f"{mid}: test phase '{phase}' はスキーマ予約のみで未対応")
    return spec


def file_ref(workspace, mod_dir, rel, what, *, executable):
    """7. hook / test の filesystem input 検証 → fileRef"""
    check_rel_string(rel, what)
    check_no_symlink_components(mod_dir, rel, what)
    p = check_containment(mod_dir, rel, what)
    st = os.lstat(p)
    if not stat.S_ISREG(st.st_mode):
        raise ResolveError(f"{what}: 通常ファイルでない: {rel}")
    if executable and not os.access(p, os.X_OK):
        raise ResolveError(f"{what}: 実行ビットが無い (chmod +x): {rel}")
    return {
        "path": str(PurePosixPath(p.relative_to(workspace).as_posix())),
        "mode": mode_str(st.st_mode),
        "sha256": sha256_file(p),
    }


def overlay_entries(workspace, src_dir, what):
    """overlay ツリーの走査。symlink は追跡しない (lstat / target 文字列のみ)"""
    entries = []
    for p in sorted(src_dir.rglob("*")):
        rel = str(p.relative_to(src_dir).as_posix())
        st = os.lstat(p)
        if stat.S_ISLNK(st.st_mode):
            entries.append(
                {"path": rel, "type": "symlink", "linkTarget": os.readlink(p)}
            )
        elif stat.S_ISDIR(st.st_mode):
            entries.append({"path": rel, "type": "dir", "mode": mode_str(st.st_mode)})
        elif stat.S_ISREG(st.st_mode):
            entries.append(
                {
                    "path": rel,
                    "type": "file",
                    "mode": mode_str(st.st_mode),
                    "sha256": sha256_file(p),
                }
            )
        else:
            raise ResolveError(f"{what}: 未対応のファイル種別: {rel}")
    return entries


def resolve_module(workspace, mod_dir, spec):
    mid = spec["metadata"]["id"]
    mod_root_rel = str(mod_dir.relative_to(workspace).as_posix())

    manifest_path = mod_dir / "module.yaml"
    manifest = {
        "path": f"{mod_root_rel}/module.yaml",
        "sha256": sha256_file(manifest_path),
    }

    overlays = []
    for ov in spec.get("overlays") or []:
        src = ov["source"]
        target = ov.get("target", "/")
        if target != "/":
            raise ResolveError(f"{mid}: overlays.target は MVP では '/' のみ (指定: {target!r})")
        check_rel_string(src, f"{mid}: overlays.source")
        src_dir = mod_dir / src
        if src_dir.is_symlink() or not src_dir.is_dir():
            raise ResolveError(f"{mid}: overlays.source '{src}' がディレクトリとして存在しない")
        check_containment(mod_dir, src, f"{mid}: overlays.source")
        overlays.append(
            {
                "source": f"{mod_root_rel}/{src}",
                "target": "/",
                "entries": overlay_entries(workspace, src_dir, f"{mid}: overlay"),
            }
        )

    hooks = {}
    for phase in SUPPORTED_HOOK_PHASES:
        refs = [
            file_ref(workspace, mod_dir, s, f"{mid}: hooks.{phase}", executable=True)
            for s in (spec.get("hooks") or {}).get(phase) or []
        ]
        if refs:
            hooks[phase] = refs
    tests = {}
    for phase in SUPPORTED_TEST_PHASES:
        refs = [
            file_ref(workspace, mod_dir, s, f"{mid}: tests.{phase}", executable=True)
            for s in (spec.get("tests") or {}).get(phase) or []
        ]
        if refs:
            tests[phase] = refs

    return {
        "id": mid,
        "source": {"type": "builtin", "root": mod_root_rel},
        "manifest": manifest,
        "packages": {"apt": list((spec.get("packages") or {}).get("apt") or [])},
        "overlays": overlays,
        "hooks": hooks,
        "tests": tests,
        "config": {},
        "resolvedDependencies": [],
    }


def check_overlay_conflicts(workspace, modules):
    """8. cross-module 制約: 同一の非ディレクトリパスへの配置を拒否"""
    placed = {}  # rootfs 内パス → (owner, type)
    trees = []
    core_files = workspace / "files"
    if core_files.is_dir():
        trees.append(("core", overlay_entries(workspace, core_files, "core: files")))
    for m in modules:
        for ov in m["overlays"]:
            trees.append((f"module[{m['id']}]", ov["entries"]))
    for owner, entries in trees:
        for e in entries:
            key = e["path"]
            if key in placed:
                prev_owner, prev_type = placed[key]
                if prev_type == "dir" and e["type"] == "dir":
                    continue
                raise ResolveError(
                    f"overlay 競合: /{key} を {prev_owner} と {owner} の両方が配置している"
                )
            placed[key] = (owner, e["type"])


def artifact_digest_of(plan):
    """artifact digest (rootfs へ影響する解決済み入力) を plan 本体から導出する
    純粋関数。resolve 時の生成と load 時の再検算の両方がこれを使う。
    requiredSecrets も含める (注入先の改ざんが digest 照合で検出されるように)"""
    return canonical_digest(
        {
            "target": plan["target"],
            "configuration": {},
            "requiredSecrets": plan["requiredSecrets"],
            "modules": [
                {
                    "id": m["id"],
                    "packages": m["packages"],
                    "overlays": m["overlays"],
                    "hooks": m["hooks"],
                    "config": m["config"],
                }
                for m in plan["modules"]
            ],
        }
    )


def tests_digest_of(plan):
    """tests digest を plan 本体から導出する純粋関数"""
    return canonical_digest(
        [
            {"module": m["id"], "phase": phase, **ref}
            for m in plan["modules"]
            for phase in SUPPORTED_TEST_PHASES
            for ref in m["tests"].get(phase, [])
        ]
    )


def compute_digests(plan):
    """10. artifact / tests / plan の 3 種の digest"""
    plan["digests"] = {
        "artifact": artifact_digest_of(plan),
        "tests": tests_digest_of(plan),
        "plan": "",
    }
    without_plan = json.loads(json.dumps(plan))
    del without_plan["digests"]["plan"]
    plan["digests"]["plan"] = canonical_digest(without_plan)
    return plan


def derive_required_secrets(request, selected):
    """manifest の secrets 宣言と BuildRequest.secretReferences を結合して
    requiredSecrets を導出する。値は読まない (参照情報のみ)。
    - 必須 secret に参照が無ければ失敗
    - 未宣言の secret への参照、未選択 module への参照は失敗
    - fileEnvironment は長さプレフィクス符号化で決定的に生成し、
      実装事故に備えて全体の重複も検査する"""
    selected_ids = {c["id"] for c in selected}
    declared = {}  # (mid, sid) → 宣言
    for c in selected:
        for sid, decl in (c["spec"].get("secrets") or {}).items():
            declared[(c["id"], sid)] = decl

    refs = request["secretReferences"]
    for mid, secrets in refs.items():
        if mid not in selected_ids:
            raise ResolveError(
                f"secretReferences: 選択されていない module への参照: {mid}"
            )
        for sid in secrets:
            if (mid, sid) not in declared:
                raise ResolveError(
                    f"secretReferences: module '{mid}' が宣言していない secret への参照: {sid}"
                )

    result = []
    seen_env = {}
    for (mid, sid), decl in sorted(declared.items()):
        ref = (refs.get(mid) or {}).get(sid)
        if ref is None:
            if decl.get("required"):
                raise ResolveError(
                    f"module '{mid}' の必須 secret '{sid}' への参照が"
                    " BuildRequest (config.yaml の secretReferences) に無い"
                )
            continue
        env = secret_file_environment(mid, sid)
        if env in seen_env:
            raise ResolveError(
                f"secret の環境変数名が衝突: {env} ({seen_env[env]} と {mid}/{sid})"
            )
        seen_env[env] = f"{mid}/{sid}"
        result.append(
            {
                "id": sid,
                "consumer": mid,
                "source": dict(ref["source"]),
                "fileEnvironment": env,
            }
        )
    return result


def resolve(workspace):
    # 各段階の中間値を明示する (将来 selection / configuration / dependencies を
    # 差し込む位置をデータフローとして固定するため)
    request = load_build_request(workspace)                      # 1
    module_schema = load_schema(workspace, "module.schema.json")

    candidates = []                                              # 2-3. 発見 + manifest 検証
    seen = set()
    for mod_dir in discover_modules(workspace):
        spec = load_manifest(workspace, mod_dir, module_schema)
        mid = spec["metadata"]["id"]
        if mid in seen:
            raise ResolveError(f"module ID が重複: {mid}")
        seen.add(mid)
        candidates.append({"id": mid, "dir": mod_dir, "spec": spec})

    selected = select_modules(request, candidates)               # 4
    configured = resolve_configuration(request, selected)        # 5
    expanded = resolve_dependencies(configured)                  # 6

    # 7. filesystem input の検証は「最終的に選択された module」に対して行う
    # (将来 dependency 解決で module が追加されても、この段階が後段にある)
    modules = []
    for c in expanded:
        m = resolve_module(workspace, c["dir"], c["spec"])
        m["config"] = c["config"]
        modules.append(m)

    check_overlay_conflicts(workspace, modules)                  # 8
    modules = order_modules(modules)                             # 9

    plan = {
        "apiVersion": API_VERSION,
        "kind": "ModulePlan",
        "target": request["target"],
        "selection": {"mode": "all-builtin", "profile": None},
        "modules": modules,
        "requiredSecrets": derive_required_secrets(request, expanded),
        "digests": {},
    }
    compute_digests(plan)                                        # 10
    schema_validate(plan, load_schema(workspace, "module-plan.schema.json"), "ModulePlan")
    return plan


def select_modules(request, candidates):
    """4. module 選択 (MVP: all-builtin。profile はここに差し込む)"""
    assert request["selection"]["mode"] == "all-builtin"
    return list(candidates)


def resolve_configuration(request, selected):
    """5. configuration の解決: module defaults ⊕ BuildRequest override →
    schema 検証 → 解決済み config。個別 module へ再適用可能な純粋処理
    (dependency で追加された module にも同じ処理を適用できる)"""
    selected_ids = {c["id"] for c in selected}
    for mid in request["moduleConfiguration"]:
        if mid not in selected_ids:
            raise ResolveError(
                f"moduleConfiguration: 選択されていない (または存在しない) module: {mid}"
            )
    out = []
    for c in selected:
        out.append({**c, "config": resolve_module_config(request, c)})
    return out


def resolve_module_config(request, candidate):
    """1 module 分の設定解決 (defaults → override merge → schema 検証)"""
    mid = candidate["id"]
    conf = load_module_configuration(candidate["spec"], mid)
    override = request["moduleConfiguration"].get(mid)
    if conf is None:
        if override:
            raise ResolveError(
                f"moduleConfiguration: module '{mid}' は configuration を宣言していない"
            )
        return {}
    merged = merge_configuration(conf["defaults"], override or {})
    # canonical JSON として正規化し、入力 mapping の記述順に依存しない
    merged = json.loads(
        json.dumps(merged, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    )
    schema_validate(merged, conf["schema"], f"{mid}: 解決済み configuration")
    return merged


def resolve_dependencies(configured):
    """6. dependencies / capabilities / conflicts の解決 (MVP: 恒等)"""
    return configured


def order_modules(modules):
    """9. 決定的な実行順 (MVP: module ID の辞書順。dependency 導入後は
    topological order との決定的な統合をここで行う)"""
    return sorted(modules, key=lambda m: m["id"])


def write_plan_atomic(plan, output):
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    data = json.dumps(plan, sort_keys=True, indent=2, ensure_ascii=False) + "\n"
    fd, tmp = tempfile.mkstemp(dir=output.parent, prefix=".module-plan.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(data)
        os.replace(tmp, output)
    except BaseException:
        os.unlink(tmp)
        raise


# --- consumer 側の検証 API ---------------------------------------------------

def load_plan(workspace, plan_path):
    plan = json.loads(Path(plan_path).read_text())
    schema_validate(plan, load_schema(workspace, "module-plan.schema.json"), "ModulePlan")
    # 全 digest を本体から再検算して照合する (どれか 1 つだけ更新した改ざん
    # plan が sidecar 照合や cache key を通過するのを防ぐ)
    without_plan = json.loads(json.dumps(plan))
    del without_plan["digests"]["plan"]
    checks = [
        ("plan", canonical_digest(without_plan)),
        ("artifact", artifact_digest_of(plan)),
        ("tests", tests_digest_of(plan)),
    ]
    for kind, expected in checks:
        if plan["digests"][kind] != expected:
            raise ResolveError(
                f"plan の digests.{kind} が本体と一致しない (改ざんまたは破損)"
            )
    # module root は builtin では modules/<id> に固定し、実体も検証する
    # (改ざん plan が root を scripts/ や別 module に差し替えるのを拒否)。
    # modules/ 自体の symlink / workspace 外もここで拒否する
    modules_root = check_modules_root(workspace).resolve(strict=True)
    for m in plan["modules"]:
        expected_root = f"modules/{m['id']}"
        if m["source"]["root"] != expected_root:
            raise ResolveError(
                f"module[{m['id']}] の source.root が不正: {m['source']['root']} "
                f"(builtin は {expected_root} 固定)"
            )
        d = workspace / expected_root
        if d.is_symlink() or not d.is_dir():
            raise ResolveError(f"module[{m['id']}] の root がディレクトリとして存在しない")
        if not d.resolve(strict=True).is_relative_to(modules_root):
            raise ResolveError(f"module[{m['id']}] の root が modules/ の外を指している")
    # config と requiredSecrets は workspace (manifest + config.yaml) から
    # 再導出して完全一致すること (辻褄を合わせた改ざん plan による
    # 設定・注入先・取得元の差し替えと、宣言変更後の stale plan を拒否)
    request = load_build_request(workspace)
    module_schema = load_schema(workspace, "module.schema.json")
    pseudo_selected = []
    for m in plan["modules"]:
        spec = load_manifest(workspace, workspace / m["source"]["root"], module_schema)
        pseudo_selected.append({"id": m["id"], "spec": spec})
        expected_config = resolve_module_config(request, pseudo_selected[-1])
        if m["config"] != expected_config:
            raise ResolveError(
                f"module[{m['id']}] の config が現在の宣言・BuildRequest から"
                "導出される値と一致しない (改ざんまたは stale)\n\nrun: make resolve"
            )
    if plan["requiredSecrets"] != derive_required_secrets(request, pseudo_selected):
        raise ResolveError(
            "plan の requiredSecrets が現在の宣言・BuildRequest と一致しない"
            " (改ざんまたは stale)\n\nrun: make resolve"
        )
    return plan


def verify_ref(workspace, module, ref, what):
    """plan に記録された fileRef を実行直前に再検証する。
    workspace 内に収まるだけでは不十分: 当該 module root 内であることを要求する
    (改ざん plan が core script や他 module を指すのを拒否)"""
    rel = ref["path"]
    check_rel_string(rel, what)
    mod_root = workspace / module["source"]["root"]
    try:
        mod_root_r = mod_root.resolve(strict=True)
        candidate = (workspace / rel).resolve(strict=True)
    except OSError as e:
        raise ResolveError(f"{what}: 実体を解決できない: {rel} ({e})") from e
    if not candidate.is_relative_to(mod_root_r):
        raise ResolveError(f"{what}: 当該 module root の外を指している: {rel}")
    check_no_symlink_components(workspace, rel, what)
    st = os.lstat(workspace / rel)
    if not stat.S_ISREG(st.st_mode):
        raise ResolveError(f"{what}: 通常ファイルでない: {rel}")
    problems = []
    if "mode" in ref and mode_str(st.st_mode) != ref["mode"]:
        problems.append(f"mode expected {ref['mode']} actual {mode_str(st.st_mode)}")
    actual = sha256_file(workspace / rel)
    if actual != ref["sha256"]:
        problems.append(f"expected {ref['sha256']}\n  actual   {actual}")
    if problems:
        raise ResolveError(
            "module plan is stale:\n  " + rel + "\n  " + "\n  ".join(problems)
            + "\n\nrun: make resolve"
        )


def verify_inputs(workspace, plan, phase):
    """phase: hooks | tests.rootfs | tests.boot | all"""
    for m in plan["modules"]:
        if phase in ("hooks", "all"):
            verify_ref(workspace, m, m["manifest"], f"module[{m['id']}] manifest")
            for ph, refs in m["hooks"].items():
                for ref in refs:
                    verify_ref(workspace, m, ref, f"module[{m['id']}] hooks.{ph}")
            for ov in m["overlays"]:
                what = f"module[{m['id']}] overlay"
                check_rel_string(ov["source"], what)
                src = workspace / ov["source"]
                if src.is_symlink() or not src.is_dir():
                    raise ResolveError(f"{what} source が不正: {ov['source']}")
                # overlay source も当該 module root 内であること
                mod_root_r = (workspace / m["source"]["root"]).resolve(strict=True)
                if not src.resolve(strict=True).is_relative_to(mod_root_r):
                    raise ResolveError(
                        f"{what} source が当該 module root の外: {ov['source']}"
                    )
                actual = overlay_entries(workspace, src, what)
                if actual != ov["entries"]:
                    raise ResolveError(
                        f"module plan is stale:\n  {ov['source']} (overlay 内容が変化)"
                        "\n\nrun: make resolve"
                    )
        for tp in SUPPORTED_TEST_PHASES:
            if phase in (f"tests.{tp}", "all"):
                for ref in m["tests"].get(tp, []):
                    verify_ref(workspace, m, ref, f"module[{m['id']}] tests.{tp}")


# --- sidecar ------------------------------------------------------------------

def write_sidecar(plan, rootfs_tar, output):
    sidecar = {
        "moduleArtifactDigest": plan["digests"]["artifact"],
        "builtWithPlanDigest": plan["digests"]["plan"],
        "rootfsTarSha256": sha256_file(rootfs_tar),
    }
    Path(output).write_text(json.dumps(sidecar, sort_keys=True, indent=2) + "\n")


def verify_sidecar(plan, rootfs_tar, sidecar_path):
    sidecar = json.loads(Path(sidecar_path).read_text())
    if sidecar.get("moduleArtifactDigest") != plan["digests"]["artifact"]:
        raise ResolveError(
            "rootfs.tar は現在の plan と異なる module 入力から作られている:\n"
            f"  plan    {plan['digests']['artifact']}\n"
            f"  sidecar {sidecar.get('moduleArtifactDigest')}\n\n"
            "rootfs を再構築すること (make rootfs)"
        )
    actual = sha256_file(rootfs_tar)
    if sidecar.get("rootfsTarSha256") != actual:
        raise ResolveError(
            "rootfs.tar が sidecar の記録と一致しない (改ざんまたは破損):\n"
            f"  sidecar {sidecar.get('rootfsTarSha256')}\n  actual  {actual}"
        )
    # builtWithPlanDigest は provenance 情報であり、再構築条件にしない
    # (test や description のみの変更で plan digest は変わるが rootfs は再利用できる)


# --- CLI ----------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--workspace", type=Path, default=DEFAULT_WORKSPACE,
                    help="リポジトリルート (fixture テスト用の差し替え)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("resolve", help="ModulePlan を生成する")
    p.add_argument("--output", required=True)

    sub.add_parser("validate", help="解決のみ実行し plan を書き出さない")

    p = sub.add_parser("explain", help="plan の要約を人間向けに表示する")
    p.add_argument("--plan", required=True)

    p = sub.add_parser("verify-inputs", help="plan 記載の入力を再検証する")
    p.add_argument("--plan", required=True)
    p.add_argument("--phase", default="all",
                   choices=["hooks", "tests.rootfs", "tests.boot", "all"])

    p = sub.add_parser("list-tests", help="検証してから TSV (id, path) を出力する")
    p.add_argument("--plan", required=True)
    p.add_argument("--phase", required=True, choices=["rootfs", "boot"])

    p = sub.add_parser("digest", help="plan の digest を出力する")
    p.add_argument("--plan", required=True)
    p.add_argument("--kind", default="artifact", choices=["artifact", "tests", "plan"])

    p = sub.add_parser(
        "required-secrets",
        help="TSV (id, consumer, source-env-name, fileEnvironment) を出力する")
    p.add_argument("--plan", required=True)

    p = sub.add_parser("module-config",
                       help="1 module の解決済み config (canonical JSON) を出力する")
    p.add_argument("--plan", required=True)
    p.add_argument("--module", required=True)

    p = sub.add_parser("write-configs",
                       help="全 module の解決済み config を <dir>/<id>.json に書き出す")
    p.add_argument("--plan", required=True)
    p.add_argument("--output-dir", required=True)

    p = sub.add_parser("write-sidecar", help="rootfs sidecar を生成する")
    p.add_argument("--plan", required=True)
    p.add_argument("--rootfs", required=True)
    p.add_argument("--output", required=True)

    p = sub.add_parser("verify-sidecar", help="plan と sidecar / rootfs.tar を照合する")
    p.add_argument("--plan", required=True)
    p.add_argument("--rootfs", required=True)
    p.add_argument("--sidecar", required=True)

    p = sub.add_parser("export-resolved", help="plan から resolved-modules.yaml を導出する")
    p.add_argument("--plan", required=True)
    p.add_argument("--output", required=True)

    args = ap.parse_args()
    workspace = args.workspace.resolve()

    try:
        if args.cmd in ("resolve", "validate"):
            plan = resolve(workspace)
            order = ", ".join(m["id"] for m in plan["modules"]) or "(なし)"
            info(f"{len(plan['modules'])} 個のモジュールを解決 (実行順: {order})")
            if args.cmd == "resolve":
                write_plan_atomic(plan, args.output)
                info(f"plan を書き出した: {args.output}")
            return

        plan = load_plan(workspace, args.plan)
        if args.cmd == "explain":
            print(f"target: {plan['target']['board']} ({plan['target']['architecture']}, "
                  f"{plan['target']['suite']})")
            print(f"selection: {plan['selection']['mode']}")
            for m in plan["modules"]:
                n_hooks = sum(len(v) for v in m["hooks"].values())
                n_tests = sum(len(v) for v in m["tests"].values())
                print(f"  {m['id']}: packages={len(m['packages']['apt'])} "
                      f"overlays={len(m['overlays'])} hooks={n_hooks} tests={n_tests}")
            for k, v in plan["digests"].items():
                print(f"digest.{k}: {v}")
        elif args.cmd == "verify-inputs":
            verify_inputs(workspace, plan, args.phase)
            info(f"plan inputs verified (phase: {args.phase})")
        elif args.cmd == "list-tests":
            verify_inputs(workspace, plan, f"tests.{args.phase}")
            for m in plan["modules"]:
                for ref in m["tests"].get(args.phase, []):
                    print(f"{m['id']}\t{ref['path']}")
        elif args.cmd == "digest":
            print(plan["digests"][args.kind])
        elif args.cmd == "required-secrets":
            for s in plan["requiredSecrets"]:
                print(f"{s['id']}\t{s['consumer']}\t{s['source']['name']}"
                      f"\t{s['fileEnvironment']}")
        elif args.cmd == "module-config":
            for m in plan["modules"]:
                if m["id"] == args.module:
                    print(json.dumps(m["config"], sort_keys=True,
                                     separators=(",", ":"), ensure_ascii=False))
                    break
            else:
                die(f"module が plan に無い: {args.module}")
        elif args.cmd == "write-configs":
            out_dir = Path(args.output_dir)
            out_dir.mkdir(parents=True, exist_ok=True)
            for m in plan["modules"]:
                (out_dir / f"{m['id']}.json").write_text(
                    json.dumps(m["config"], sort_keys=True,
                               separators=(",", ":"), ensure_ascii=False) + "\n")
        elif args.cmd == "write-sidecar":
            write_sidecar(plan, args.rootfs, args.output)
        elif args.cmd == "verify-sidecar":
            verify_sidecar(plan, args.rootfs, args.sidecar)
            info("sidecar verified (artifact digest / rootfs.tar sha256)")
        elif args.cmd == "export-resolved":
            out = {
                "apiVersion": API_VERSION,
                "modules": [
                    {"id": m["id"], "source": m["source"]["type"],
                     "path": m["source"]["root"]}
                    for m in plan["modules"]
                ],
            }
            Path(args.output).parent.mkdir(parents=True, exist_ok=True)
            Path(args.output).write_text(
                yaml.safe_dump(out, sort_keys=False, allow_unicode=True))
    except ResolveError as e:
        die(str(e))


if __name__ == "__main__":
    main()
