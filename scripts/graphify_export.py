#!/usr/bin/env python3
"""Export a code+docs dependency graph for graphify.

Reads .graphify/config.json in the repo root and writes
outputs/graph-export.json. Stdlib only, no dependencies.

Node kinds: module (source file), doc (README/docs), schema (json-schema/openapi).
Edge kinds: imports (code), references ($ref in schemas), mentions (doc -> module
  heuristic, only when a module's dotted/path name is mentioned verbatim in a doc).
"""
from __future__ import annotations

import ast
import fnmatch
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

SKIP_DIRS = {
    ".git", ".venv", "venv", "node_modules", "__pycache__", ".pnpm",
    ".ruff_cache", ".mypy_cache", ".pytest_cache", ".storybook",
    "storybook-static", "test-results", "dist", "build", "artifacts",
    "models", "bundles", "data", "migrations", ".github", "sbom",
}
REF_RE = re.compile(r'"\$ref"\s*:\s*"([^"#][^"]*)"')
TS_IMPORT_RE = re.compile(r'''(?:from|import)\s+['"](\.\.?/[^'"]+)['"]|require\(['"](\.\.?/[^'"]+)['"]\)''')


def is_appledouble(p: Path) -> bool:
    return p.name.startswith("._")


def iter_files(root: Path, rel_globs: list[str]) -> list[Path]:
    out = []
    for g in rel_globs:
        for p in root.glob(g):
            if p.is_file() and not is_appledouble(p) and not any(part in SKIP_DIRS for part in p.parts):
                out.append(p)
    return sorted(set(out))


def module_id(repo_root: Path, path: Path) -> str:
    return str(path.relative_to(repo_root).with_suffix(""))


def load_config(repo_root: Path) -> dict:
    cfg_path = repo_root / ".graphify" / "config.json"
    return json.loads(cfg_path.read_text())


# ---- Python ----

def resolve_python_import(module: str | None, level: int, current: Path, repo_root: Path, package: str, base_dir: Path) -> str | None:
    if level > 0:
        base = current.parent
        for _ in range(level - 1):
            base = base.parent
        if module:
            target = base.joinpath(*module.split("."))
        else:
            target = base
    else:
        if not module or not (module == package or module.startswith(package + ".")):
            return None
        target = base_dir.joinpath(*module.split("."))

    for candidate in (target.with_suffix(".py"), target / "__init__.py"):
        if candidate.exists() and not is_appledouble(candidate):
            return module_id(repo_root, candidate)
    return None


def scan_python(repo_root: Path, src_roots: list[str], package: str) -> tuple[dict, list]:
    nodes, edges = {}, []
    files = []
    for root in src_roots:
        files.extend(iter_files(repo_root, [f"{root}/**/*.py"]))
    # Absolute imports (`import package.mod`) resolve relative to the parent of
    # the src root (e.g. "src/"), not the repo root, since packages usually live
    # inside a src/ layout.
    base_dir = repo_root / Path(src_roots[0]).parent if src_roots else repo_root
    for f in files:
        mid = module_id(repo_root, f)
        nodes[mid] = {"id": mid, "title": f.name, "type": "module", "language": "python"}
        try:
            tree = ast.parse(f.read_text(errors="replace"), filename=str(f))
        except SyntaxError:
            continue
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    tgt = resolve_python_import(alias.name, 0, f, repo_root, package, base_dir)
                    if tgt and tgt != mid:
                        edges.append({"source": mid, "target": tgt, "kind": "imports"})
            elif isinstance(node, ast.ImportFrom):
                tgt = resolve_python_import(node.module, node.level, f, repo_root, package, base_dir)
                if tgt and tgt != mid:
                    edges.append({"source": mid, "target": tgt, "kind": "imports"})
    return nodes, edges


# ---- TypeScript / JavaScript ----

def resolve_ts_import(spec: str, current: Path, repo_root: Path) -> str | None:
    target = (current.parent / spec).resolve()
    candidates = [target]
    for ext in (".ts", ".tsx", ".js", ".jsx"):
        candidates.append(target.with_suffix(ext))
    for ext in (".ts", ".tsx", ".js", ".jsx"):
        candidates.append(target / f"index{ext}")
    for c in candidates:
        if c.exists() and not is_appledouble(c):
            try:
                return module_id(repo_root, c)
            except ValueError:
                return None
    return None


def scan_typescript(repo_root: Path, src_roots: list[str]) -> tuple[dict, list]:
    nodes, edges = {}, []
    files = []
    for root in src_roots:
        for ext in ("ts", "tsx", "js", "jsx"):
            files.extend(iter_files(repo_root, [f"{root}/**/*.{ext}"]))
    for f in sorted(set(files)):
        mid = module_id(repo_root, f)
        nodes[mid] = {"id": mid, "title": f.name, "type": "module", "language": "typescript"}
        text = f.read_text(errors="replace")
        for m in TS_IMPORT_RE.finditer(text):
            spec = m.group(1) or m.group(2)
            tgt = resolve_ts_import(spec, f, repo_root)
            if tgt and tgt != mid:
                edges.append({"source": mid, "target": tgt, "kind": "imports"})
    return nodes, edges


# ---- Schemas (OpenAPI / JSON Schema) ----

def scan_schema(repo_root: Path, schema_globs: list[str]) -> tuple[dict, list]:
    nodes, edges = {}, []
    files = iter_files(repo_root, schema_globs)
    for f in files:
        sid = module_id(repo_root, f)
        nodes[sid] = {"id": sid, "title": f.name, "type": "schema", "language": "json"}
        text = f.read_text(errors="replace")
        for m in REF_RE.finditer(text):
            ref = m.group(1).split("#")[0]
            if not ref:
                continue
            target = (f.parent / ref).resolve()
            try:
                tid = module_id(repo_root, target)
            except ValueError:
                continue
            if tid in nodes or target.exists():
                edges.append({"source": sid, "target": tid, "kind": "references"})
    return nodes, edges


# ---- Docs ----

def scan_docs(repo_root: Path, doc_globs: list[str]) -> dict:
    nodes = {}
    for f in iter_files(repo_root, doc_globs):
        did = module_id(repo_root, f)
        title = f.stem
        for line in f.read_text(errors="replace").splitlines():
            if line.startswith("# "):
                title = line[2:].strip()
                break
        nodes[did] = {"id": did, "title": title, "type": "doc", "language": "markdown"}
    return nodes


def build_graph(repo_root: Path) -> dict:
    cfg = load_config(repo_root)
    nodes, edges = {}, []

    lang = cfg.get("language")
    if lang == "python":
        n, e = scan_python(repo_root, cfg.get("src_roots", []), cfg.get("package", ""))
        nodes.update(n)
        edges.extend(e)
    elif lang == "typescript":
        n, e = scan_typescript(repo_root, cfg.get("src_roots", []))
        nodes.update(n)
        edges.extend(e)

    if cfg.get("schema_globs"):
        n, e = scan_schema(repo_root, cfg["schema_globs"])
        nodes.update(n)
        edges.extend(e)

    nodes.update(scan_docs(repo_root, cfg.get("doc_globs", [])))

    unresolved = []
    valid_edges = []
    for e in edges:
        if e["target"] in nodes:
            valid_edges.append(e)
        else:
            unresolved.append(f"{e['source']} -> {e['target']}")

    for n in nodes.values():
        n["inDegree"] = sum(1 for e in valid_edges if e["target"] == n["id"])
        n["outDegree"] = sum(1 for e in valid_edges if e["source"] == n["id"])

    return {
        "generated": datetime.now(timezone.utc).isoformat(),
        "repo": cfg.get("repo", repo_root.name),
        "nodes": list(nodes.values()),
        "edges": valid_edges,
        "warnings": {"unresolvedEdges": unresolved},
    }


if __name__ == "__main__":
    repo_root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    graph = build_graph(repo_root)
    out = repo_root / "outputs" / "graph-export.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(graph, ensure_ascii=False, indent=2))
    print(f"{graph['repo']}: {len(graph['nodes'])} nodos, {len(graph['edges'])} aristas -> {out}")
    if graph["warnings"]["unresolvedEdges"]:
        print(f"  (aristas no resueltas: {len(graph['warnings']['unresolvedEdges'])})")
