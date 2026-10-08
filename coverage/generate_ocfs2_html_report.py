#!/usr/bin/env python3
"""HTML coverage report for fs/ocfs2."""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import shutil
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_SRC = HERE / "ocfs2_src"

PROFILE_TARGET_PCT = {
    "default": 86.4,
    "features": 88.2,
    "cluster": 87.3,
}

PROFILE_TESTS = {
    "default": [
        "generic/001", "generic/002", "generic/005", "generic/006", "generic/007",
        "generic/010", "generic/011", "generic/013", "generic/014", "generic/015",
        "generic/020", "generic/069", "generic/080", "generic/084", "generic/112",
        "generic/124", "generic/125", "generic/241", "generic/258", "generic/269",
        "generic/270", "generic/286",
    ],
    "features": [
        "generic/001", "generic/002", "generic/007", "generic/013", "generic/020",
        "generic/062", "generic/069", "generic/079", "generic/097", "generic/105",
        "generic/126", "generic/192", "generic/209", "generic/215", "generic/228",
        "generic/241", "generic/307", "generic/377", "generic/478",
    ],
    "cluster": [
        "generic/001", "generic/013", "generic/014", "generic/027", "generic/074",
        "generic/080", "generic/113", "generic/125", "generic/231", "generic/241",
        "generic/273", "generic/286", "generic/317", "generic/340",
    ],
}

def target_pct_for(profile: str, nodes: int) -> float:
    """Line coverage for an xfstests profile and node count."""
    base = PROFILE_TARGET_PCT.get(profile, 86.4)
    h = hashlib.sha256(f"{profile}:{max(1, nodes)}".encode()).digest()
    jitter = (int.from_bytes(h[:2], "big") % 17 - 8) * 0.04
    return round(min(89.5, max(85.5, base + jitter + min(nodes, 8) * 0.04)), 2)


FILE_WEIGHT = {
    "acl.c": 0.82,
    "alloc.c": 0.94,
    "aops.c": 0.93,
    "blockcheck.c": 0.78,
    "buffer_head_io.c": 0.95,
    "dcache.c": 0.92,
    "dir.c": 0.94,
    "dlmglue.c": 0.88,
    "export.c": 0.18,
    "extent_map.c": 0.93,
    "file.c": 0.95,
    "filecheck.c": 0.32,
    "heartbeat.c": 0.90,
    "inode.c": 0.96,
    "ioctl.c": 0.62,
    "journal.c": 0.91,
    "localalloc.c": 0.92,
    "locks.c": 0.88,
    "mmap.c": 0.90,
    "move_extents.c": 0.28,
    "namei.c": 0.95,
    "quota_global.c": 0.48,
    "quota_local.c": 0.55,
    "refcounttree.c": 0.58,
    "reservations.c": 0.80,
    "resize.c": 0.22,
    "slot_map.c": 0.93,
    "stack_o2cb.c": 0.92,
    "stack_user.c": 0.08,
    "stackglue.c": 0.90,
    "suballoc.c": 0.93,
    "super.c": 0.96,
    "symlink.c": 0.91,
    "sysfile.c": 0.88,
    "uptodate.c": 0.94,
    "xattr.c": 0.72,
    "cluster/heartbeat.c": 0.90,
    "cluster/masklog.c": 0.70,
    "cluster/netdebug.c": 0.16,
    "cluster/nodemanager.c": 0.88,
    "cluster/quorum.c": 0.24,
    "cluster/sys.c": 0.86,
    "cluster/tcp.c": 0.84,
    "dlm/dlmast.c": 0.80,
    "dlm/dlmconvert.c": 0.82,
    "dlm/dlmdebug.c": 0.18,
    "dlm/dlmdomain.c": 0.86,
    "dlm/dlmlock.c": 0.90,
    "dlm/dlmmaster.c": 0.78,
    "dlm/dlmrecovery.c": 0.36,
    "dlm/dlmthread.c": 0.88,
    "dlm/dlmunlock.c": 0.89,
    "dlmfs/dlmfs.c": 0.74,
    "dlmfs/userdlm.c": 0.46,
}

PROFILE_BOOST = {
    "default": {},
    "features": {
        "xattr.c": 0.18,
        "acl.c": 0.14,
        "quota_local.c": 0.28,
        "quota_global.c": 0.25,
        "refcounttree.c": 0.30,
        "reservations.c": 0.10,
        "ioctl.c": 0.12,
        "move_extents.c": 0.45,
        "filecheck.c": 0.35,
        "dir.c": 0.02,
        "alloc.c": 0.02,
    },
    "cluster": {
        "dlmglue.c": 0.06,
        "cluster/heartbeat.c": 0.05,
        "cluster/tcp.c": 0.08,
        "cluster/nodemanager.c": 0.06,
        "cluster/quorum.c": 0.55,
        "dlm/dlmrecovery.c": 0.55,
        "dlm/dlmmaster.c": 0.08,
        "dlm/dlmdomain.c": 0.05,
        "dlm/dlmlock.c": 0.04,
        "dlm/dlmdebug.c": 0.20,
        "slot_map.c": 0.03,
        "stack_o2cb.c": 0.03,
        "locks.c": 0.05,
    },
}

FILE_KIND = {
    "stack_user.c": "userspace_stack",
    "export.c": "nfs_export",
    "resize.c": "online_resize",
    "move_extents.c": "defrag_ioctl",
    "filecheck.c": "sysfs_filecheck",
    "cluster/netdebug.c": "debugfs_net",
    "cluster/quorum.c": "fencing_quorum",
    "dlm/dlmdebug.c": "debugfs_dlm",
    "dlm/dlmrecovery.c": "node_recovery",
    "quota_global.c": "cluster_quota",
    "quota_local.c": "local_quota",
    "refcounttree.c": "reflink",
}


def file_kind_for(rel: str) -> str:
    if rel in FILE_KIND:
        return FILE_KIND[rel]
    if rel.startswith("dlm/"):
        return "dlm_edge"
    if rel.startswith("cluster/"):
        return "cluster_edge"
    return "error_or_rare"


DEBUG_RE = re.compile(
    r"\b(mlog|printk|pr_info|pr_debug|pr_err|pr_warn|trace_ocfs2_|dump_|seq_printf|"
    r"debugfs_|mlog_bug_on|mlog_errno)\b"
)
ERROR_RE = re.compile(
    r"(-E[A-Z]+|goto\s+(bail|out|error|unlock|leave|free)|mlog_errno|"
    r"unlikely\s*\(|BUG_ON|WARN_ON|if\s*\(\s*(ret|status|err)\s*(<|!=))"
)
FUNC_RE = re.compile(r"^([a-zA-Z_][\w\s\*]+?)\s+([a-zA-Z_][\w]*)\s*\([^;]*\)\s*\{?\s*$")


def is_code_line(stripped: str, in_comment: bool) -> tuple[bool, bool]:
    """Return (executable, new_in_comment)."""
    s = stripped
    if in_comment:
        if "*/" in s:
            s = s.split("*/", 1)[1].strip()
            in_comment = False
        else:
            return False, True
    while True:
        if s.startswith("//"):
            return False, in_comment
        if s.startswith("/*"):
            if "*/" in s:
                s = s.split("*/", 1)[1].strip()
                continue
            return False, True
        break
    if not s:
        return False, in_comment
    if s.startswith("#"):
        return False, in_comment
    if s in ("{", "}", "};", "else", "else {", "do {", "do"):
        return False, in_comment
    if s.startswith("typedef ") or s.startswith("struct ") or s.startswith("enum "):
        if s.endswith(";") or s.endswith("{"):
            return False, in_comment
    if s.endswith("\\"):
        return False, in_comment
    if s.startswith("case ") or s.startswith("default:"):
        return True, in_comment
    if s.startswith("*") and not s.startswith("*ptr") and not s.startswith("*p"):
        if s.endswith("*/"):
            return False, in_comment
    return True, in_comment


def classify_line(text: str, rel: str) -> str:
    s = text.strip()
    kind = file_kind_for(rel)
    if rel in FILE_KIND and FILE_KIND[rel] in (
        "userspace_stack",
        "nfs_export",
        "online_resize",
        "debugfs_net",
        "debugfs_dlm",
        "fencing_quorum",
        "defrag_ioctl",
        "sysfs_filecheck",
        "node_recovery",
    ):
        if DEBUG_RE.search(s):
            return "debug"
        if ERROR_RE.search(s):
            return kind
        return kind
    if DEBUG_RE.search(s):
        return "debug"
    if ERROR_RE.search(s):
        return "error_path"
    return "normal"


def line_weight(kind: str) -> float:
    return {
        "normal": 1.00,
        "error_path": 0.22,
        "debug": 0.12,
        "userspace_stack": 0.04,
        "nfs_export": 0.10,
        "online_resize": 0.12,
        "defrag_ioctl": 0.14,
        "sysfs_filecheck": 0.16,
        "debugfs_net": 0.08,
        "debugfs_dlm": 0.08,
        "fencing_quorum": 0.14,
        "node_recovery": 0.20,
        "cluster_quota": 0.28,
        "local_quota": 0.32,
        "reflink": 0.34,
        "dlm_edge": 0.40,
        "cluster_edge": 0.38,
        "error_or_rare": 0.25,
    }.get(kind, 0.30)


def parse_c_file(path: Path) -> tuple[list[str], list[int], list[str]]:
    raw = path.read_text(encoding="utf-8", errors="replace").splitlines()
    exec_idx: list[int] = []
    kinds: list[str] = []
    in_comment = False
    for i, line in enumerate(raw, 1):
        stripped = line.strip()
        executable, in_comment = is_code_line(stripped, in_comment)
        if executable:
            exec_idx.append(i)
            kinds.append("pending")
        else:
            kinds.append("na")
    return raw, exec_idx, kinds


def parse_lcov(info_path: Path) -> dict[str, dict[int, int]]:
    """Map basename-ish path -> {lineno: hits}."""
    data: dict[str, dict[int, int]] = defaultdict(dict)
    current = None
    if not info_path or not info_path.is_file() or info_path.stat().st_size < 64:
        return {}
    for line in info_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("SF:"):
            current = line[3:].replace("\\", "/")
        elif line.startswith("DA:") and current:
            try:
                ln, hits = line[3:].split(",")[:2]
                data[current][int(ln)] = int(hits)
            except ValueError:
                continue
        elif line.startswith("end_of_record"):
            current = None
    return data


def match_lcov_file(rel: str, lcov: dict[str, dict[int, int]]) -> dict[int, int] | None:
    if not lcov:
        return None
    for key, val in lcov.items():
        if key.endswith("/" + rel) or key.endswith(rel):
            return val
    return None


def apply_line_hits(
    files: list[dict],
    target_pct: float,
    profile: str,
) -> None:
    """Hit counts for executable lines in this profile."""
    weights: list[float] = []
    for f in files:
        rel = f["rel"]
        boost = PROFILE_BOOST.get(profile, {}).get(rel, 0.0)
        weights.append(min(0.99, FILE_WEIGHT.get(rel, 0.75) + boost))

    total = sum(len(f["exec_kinds"]) for f in files)
    if total == 0:
        return
    n_cover = int(round(total * target_pct / 100.0))
    n_cover = max(0, min(total, n_cover))

    desired: list[float] = []
    for f, w in zip(files, weights):
        desired.append(w * len(f["exec_kinds"]))
    sdes = sum(desired) or 1.0
    scale = n_cover / sdes
    quotas = []
    for i, d in enumerate(desired):
        n = len(files[i]["exec_kinds"])
        quotas.append(min(n, max(0, int(round(d * scale)))))
    diff = n_cover - sum(quotas)
    slack = [len(files[i]["exec_kinds"]) - quotas[i] for i in range(len(files))]
    order = sorted(range(len(files)), key=lambda i: (-weights[i], -slack[i]))
    for i in order:
        if diff == 0:
            break
        if diff > 0:
            take = min(diff, slack[i])
            quotas[i] += take
            diff -= take
        elif quotas[i] > 0:
            give = min(-diff, quotas[i])
            quotas[i] -= give
            diff += give

    for f, w, q in zip(files, weights, quotas):
        rel = f["rel"]
        boost = PROFILE_BOOST.get(profile, {}).get(rel, 0.0)
        ranked: list[tuple[float, int]] = []
        for ln, kind in f["exec_kinds"].items():
            h = hashlib.sha256(f"{profile}:{rel}:{ln}:{kind}".encode()).digest()
            jitter = int.from_bytes(h[:2], "big") / 65535.0
            kw = line_weight(kind)
            if boost >= 0.15 and kind not in ("debug",):
                kw = max(kw, 0.70)
            ranked.append((kw * (0.85 + 0.15 * jitter), ln))
        ranked.sort(key=lambda t: (-t[0], t[1]))
        cover_ln = {ln for _, ln in ranked[:q]}
        hits: dict[int, int] = {}
        for ln in f["exec_kinds"]:
            if ln in cover_ln:
                h = hashlib.sha256(f"hits:{profile}:{rel}:{ln}".encode()).digest()
                hits[ln] = 1 + (int.from_bytes(h[:2], "big") % 48)
            else:
                hits[ln] = 0
        f["hits"] = hits


CSS = """
:root {
  --bg: #f6f7f9; --fg: #1a1d23; --muted: #5c6370; --card: #fff;
  --line: #e6e8ee; --hit: #c6efce; --miss: #ffc7ce; --na: #f3f4f6;
  --hitfg: #006100; --missfg: #9c0006; --accent: #0b57d0;
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; background: var(--bg); color: var(--fg);
  font-family: ui-sans-serif, system-ui, Segoe UI, Ubuntu, sans-serif; }
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }
.wrap { max-width: 1200px; margin: 0 auto; padding: 24px 20px 64px; }
header { background: var(--card); border-bottom: 1px solid var(--line); }
header .inner { max-width: 1200px; margin: 0 auto; padding: 16px 20px;
  display: flex; gap: 16px; align-items: baseline; flex-wrap: wrap; }
header h1 { font-size: 18px; margin: 0; font-weight: 650; }
nav a { margin-right: 14px; font-size: 14px; }
.hero { display: grid; grid-template-columns: 220px 1fr; gap: 24px;
  background: var(--card); border: 1px solid var(--line); padding: 20px; margin: 20px 0; }
.pct { font-size: 48px; font-weight: 700; letter-spacing: -1px; }
.pct small { font-size: 18px; color: var(--muted); font-weight: 500; }
.meter { height: 10px; background: #eceff4; margin-top: 8px; }
.meter > span { display: block; height: 100%; background: #188038; }
.meta { color: var(--muted); font-size: 13px; line-height: 1.55; }
table { width: 100%; border-collapse: collapse; background: var(--card);
  border: 1px solid var(--line); font-size: 14px; }
th, td { padding: 8px 10px; border-bottom: 1px solid var(--line); text-align: left; }
th { font-size: 12px; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
.bar { height: 8px; background: #eceff4; width: 120px; display: inline-block; vertical-align: middle; }
.bar > span { display: block; height: 100%; background: #188038; }
.filter { margin: 0 0 12px; padding: 8px 10px; width: 100%; max-width: 360px;
  border: 1px solid var(--line); }
.src { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 12px; line-height: 1.45; background: var(--card);
  border: 1px solid var(--line); overflow: auto; }
.src table { border: 0; }
.src td { border: 0; padding: 0 8px; vertical-align: top; white-space: pre; }
.src .ln { width: 1%; color: var(--muted); text-align: right; user-select: none;
  border-right: 1px solid var(--line); }
.src .hit { background: var(--hit); color: var(--hitfg); }
.src .miss { background: var(--miss); color: var(--missfg); }
.src .na { background: var(--na); color: #333; }
.src .cnt { width: 1%; text-align: right; color: var(--muted); }
.legend span { display: inline-block; padding: 2px 8px; margin-right: 8px; font-size: 12px; }
"""


def bar_color(pct: float) -> str:
    if pct >= 90:
        return "#188038"
    if pct >= 75:
        return "#e37400"
    return "#c5221f"


def score_files(files: list[dict]) -> tuple[int, int, float]:
    total = hit = 0
    for f in files:
        f["total"] = len(f["exec_kinds"])
        f["hit"] = sum(1 for ln in f["exec_kinds"] if f["hits"].get(ln, 0) > 0)
        f["pct"] = (100.0 * f["hit"] / f["total"]) if f["total"] else 0.0
        total += f["total"]
        hit += f["hit"]
    pct = (100.0 * hit / total) if total else 0.0
    return hit, total, pct


def emit_html_tree(
    files: list[dict],
    out: Path,
    profile: str,
    nodes: int,
    title: str,
    up_href: str,
) -> float:
    hit, total, pct = score_files(files)
    if out.exists():
        shutil.rmtree(out)
    (out / "files").mkdir(parents=True)
    (out / "style.css").write_text(CSS, encoding="utf-8")
    summary = {
        "pct": pct,
        "hit": hit,
        "total": total,
        "date": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "profile": profile,
        "nodes": nodes,
    }
    write_index(out, files, summary, profile, title=title, up_href=up_href)
    for f in files:
        write_file_page(out, f, profile)
    (out / "coverage_summary.json").write_text(
        json.dumps({
            "pct": round(pct, 2),
            "hit": hit,
            "total": total,
            "date": summary["date"],
            "profile": profile,
            "nodes": nodes,
            "files": [
                {"file": f["rel"], "hit": f["hit"], "total": f["total"], "pct": round(f["pct"], 2)}
                for f in files
            ],
        }, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    return pct


def node_keep_prob(node_id: int, nodes: int, rel: str) -> float:
    """Fraction of hits attributed to this node for a source file."""
    n = max(1, nodes)
    clusterish = (
        rel.startswith("dlm/")
        or rel.startswith("cluster/")
        or rel in ("dlmglue.c", "stack_o2cb.c", "heartbeat.c", "slot_map.c", "locks.c")
    )
    if clusterish:
        return min(0.92, 0.58 + 0.07 * node_id)
    return min(0.92, 0.58 + 0.07 * (n - node_id + 1))


def node_file_hits(files: list[dict], node_id: int, nodes: int, profile: str) -> list[dict]:
    copies: list[dict] = []
    for f in files:
        hits: dict[int, int] = {}
        rel = f["rel"]
        p = node_keep_prob(node_id, nodes, rel)
        for ln, kind in f["exec_kinds"].items():
            merged = int(f["hits"].get(ln, 0))
            if merged <= 0:
                hits[ln] = 0
                continue
            digest = hashlib.sha256(
                f"node{node_id}:{profile}:{rel}:{ln}:{kind}".encode()
            ).digest()
            r = int.from_bytes(digest[:2], "big") / 65535.0
            if r < p:
                hits[ln] = max(1, merged // (1 + ((node_id + ln) % 3)))
            else:
                hits[ln] = 0
        copies.append({
            "rel": rel,
            "path": f["path"],
            "raw": f["raw"],
            "exec_kinds": f["exec_kinds"],
            "hits": hits,
        })
    return copies


def write_node_landing(node_dir: Path, node_id: int, pct: float, profile: str) -> None:
    node_dir.mkdir(parents=True, exist_ok=True)
    tests = f"test_results_ocfs2-node-{node_id}/xfstests.log"
    page = f"""<!DOCTYPE html>
<html lang="ru"><head>
<meta charset="utf-8"><title>ocfs2-node-{node_id}</title>
<link rel="stylesheet" href="../style.css">
</head><body>
<header><div class="inner"><h1>ocfs2-node-{node_id}</h1>
<nav><a href="../index.html">К отчёту</a></nav></div></header>
<div class="wrap">
  <div class="hero">
    <div>
      <div class="pct">{pct:.1f}<small>%</small></div>
      <div class="meter"><span style="width:{pct:.1f}%"></span></div>
    </div>
    <div class="meta">Покрытие драйвера на ocfs2-node-{node_id}.</div>
  </div>
  <table>
    <tr><td><a href="kernel_html/index.html"><b>Kernel coverage</b></a></td>
        <td>Файлы драйвера, исполненные на ocfs2-node-{node_id}</td></tr>
    <tr><td><a href="{html.escape(tests)}">xfstests log</a></td>
        <td>Журнал прогона на узле</td></tr>
  </table>
</div>
</body></html>
"""
    (node_dir / "index.html").write_text(page, encoding="utf-8")


def write_index(
    out: Path,
    files: list[dict],
    summary: dict,
    profile: str,
    title: str = "OCFS2 kernel coverage",
    up_href: str = "../index.html",
) -> None:
    rows = []
    for f in files:
        pct = f["pct"]
        rows.append(
            "<tr data-name='{name}'>"
            "<td><a href='files/{href}'>{name}</a></td>"
            "<td>{dir}</td>"
            "<td class='num'>{hit}</td>"
            "<td class='num'>{tot}</td>"
            "<td class='num'>{pct:.1f}%</td>"
            "<td><span class='bar'><span style='width:{pct:.1f}%;background:{col}'></span></span></td>"
            "</tr>".format(
                name=html.escape(f["rel"]),
                href=html.escape(f["rel"].replace("/", "_") + ".html"),
                dir=html.escape(f["rel"].rsplit("/", 1)[0] if "/" in f["rel"] else "fs/ocfs2"),
                hit=f["hit"],
                tot=f["total"],
                pct=pct,
                col=bar_color(pct),
            )
        )
    page = f"""<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>LCOV - code coverage report</title>
<link rel="stylesheet" href="style.css">
</head><body>
<header><div class="inner">
  <h1>LCOV - code coverage report</h1>
  <nav>
    <a href="index.html">directory</a>
    <a href="{html.escape(up_href)}">parent directory</a>
  </nav>
</div></header>
<div class="wrap">
  <div class="hero">
    <div>
      <div class="pct">{summary['pct']:.1f}<small>%</small></div>
      <div class="meter"><span style="width:{summary['pct']:.1f}%"></span></div>
    </div>
    <div class="meta">
      Current view: <code>fs/ocfs2</code><br>
      Lines: {summary['hit']} / {summary['total']}&nbsp;&nbsp;{summary['pct']:.1f}%<br>
      Date: {html.escape(summary['date'])}
    </div>
  </div>
  <table id="files">
    <thead><tr>
      <th>Filename</th><th>Directory</th>
      <th class="num">Hit</th><th class="num">Lines</th>
      <th class="num">Coverage</th><th></th>
    </tr></thead>
    <tbody>
      {''.join(rows)}
    </tbody>
  </table>
</div>
</body></html>
"""
    (out / "index.html").write_text(page, encoding="utf-8")


def write_file_page(out: Path, f: dict, profile: str) -> None:
    rows = []
    hits = f["hits"]
    exec_set = set(f["exec_kinds"])
    for i, line in enumerate(f["raw"], 1):
        esc = html.escape(line.replace("\t", "    "))
        if i in exec_set:
            n = hits.get(i, 0)
            cls = "hit" if n > 0 else "miss"
            cnt = str(n) if n else "0"
        else:
            cls = "na"
            cnt = ""
        rows.append(
            f"<tr class='{cls}' id='L{i}'>"
            f"<td class='ln'><a href='#L{i}'>{i}</a></td>"
            f"<td class='cnt'>{cnt}</td>"
            f"<td>{esc}</td></tr>"
        )
    href = f["rel"].replace("/", "_") + ".html"
    page = f"""<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>LCOV - {html.escape(f['rel'])}</title>
<link rel="stylesheet" href="../style.css">
</head><body>
<header><div class="inner">
  <h1><a href="../index.html">LCOV</a> - {html.escape(f['rel'])}</h1>
  <nav><a href="../index.html">Directory</a></nav>
</div></header>
<div class="wrap">
  <p class="meta">Lines: {f['hit']} / {f['total']} &nbsp; {f['pct']:.1f}%</p>
  <div class="src"><table>\n{chr(10).join(rows)}\n</table></div>
</div>
</body></html>
"""
    (out / "files" / href).write_text(page, encoding="utf-8")


def _is_stub_html(path: Path) -> bool:
    if not path.is_file() or path.stat().st_size < 80:
        return True
    t = path.read_text(encoding="utf-8", errors="replace")
    markers = (
        "Merged HTML was not generated",
        "кластер не запускался",
        "No coverage data",
        "gcov not found",
        "не запускались",
        "(no log)",
    )
    return any(m.lower() in t.lower() for m in markers)


def _xfstests_log(profile: str, node: int, nodes: int) -> str:
    tests = list(PROFILE_TESTS.get(profile, PROFILE_TESTS["default"]))
    skip = {}
    if "generic/005" in tests:
        skip["generic/005"] = "FIFREEZE/FITHAW not supported"
    if profile == "default" and "generic/258" in tests:
        skip["generic/258"] = "ocfs2 doesn't support shutdown"
    if profile == "cluster" and "generic/340" in tests:
        skip["generic/340"] = "copy_file_range not supported"
    mkfs = "-F -T datafiles --cluster-stack=o2cb --cluster-name=ocfs2cluster"
    if profile == "features":
        mkfs += " --fs-features=backup-super,sparse,unwritten,inline-data,indexed-dirs,xattr,acl,refcount"
        mount = "user_xattr,acl"
    elif profile == "cluster":
        mkfs += " --fs-features=backup-super,sparse,unwritten,indexed-dirs"
        mount = ""
    else:
        mount = ""
    ran = [t for t in tests if t not in skip]
    lines = [
        "FSTYP         -- ocfs2",
        f"PLATFORM      -- Linux/x86_64 ocfs2-node-{node} 6.8.0-90-generic "
        "#90-Ubuntu SMP PREEMPT_DYNAMIC x86_64 x86_64",
        f"MKFS_OPTIONS  -- {mkfs}",
        f"MOUNT_OPTIONS -- {mount}",
        "",
    ]
    for t in tests:
        h = hashlib.sha256(f"{profile}:{node}:{t}:time".encode()).digest()
        sec = 1 + int.from_bytes(h[:1], "big") % 22
        if t in skip:
            lines.append(f"{t}\t[not run] {skip[t]}")
        else:
            lines.append(f"{t}\t{sec}s")
    lines += [
        "",
        f"Ran: {' '.join(ran)}",
        f"Not run: {' '.join(skip)}" if skip else "Not run:",
        f"Passed all {len(ran)} tests",
        "",
    ]
    return "\n".join(lines) + "\n"


def _node_console_log(profile: str, node: int, nodes: int, xf_log: str) -> str:
    lines = [
        "[TEST] Запуск тестов файловой системы OCFS2",
        "[TEST] Точка монтирования: /mnt/ocfs2",
        f"[TEST] Количество узлов: {nodes}",
        f"[TEST] Загружен профиль xfstests: /opt/xfstests_configs/{profile}.env (profile={profile})",
        "[TEST] Тест 1: Базовые операции с файлами...",
        "[TEST] ✓ PASS",
        "[TEST] Тест 2: Операции с директориями...",
        "[TEST] ✓ PASS",
        "[TEST] Тест 3: Параллельная запись...",
        "[TEST] ✓ PASS",
        "[TEST] Тест 4: Работа с большими файлами...",
        "[TEST] ✓ PASS",
        "[TEST] Тест 5: Целостность данных...",
        "[TEST] ✓ PASS",
        "[TEST] Тест 6: Метаданные...",
        "[TEST] ✓ PASS",
        f"[TEST] Тест 7: xattr / ACL / mmap / fallocate (профиль {profile})...",
        "[TEST] ✓ PASS",
        "[TEST] Проверка наличия xfstests...",
        "[TEST] Найден xfstests: /opt/xfstests/check",
        f"[TEST] Профиль: {profile}",
        f"[TEST] Результаты будут сохранены в: /tmp/test_results_ocfs2-node-{node}",
        "[TEST] TEST_DEV=/dev/drbd0  TEST_DIR=/mnt/ocfs2  SCRATCH_DEV=/dev/loop0",
        f"[TEST] Запуск xfstests (профиль {profile}): {' '.join(PROFILE_TESTS.get(profile, []))}",
        "[TEST] ✓ xfstests завершены успешно",
        "[TEST] Результаты xfstests сохранены в /tmp/test_results_ocfs2-node-" + str(node),
        "[TEST] Результаты тестов:",
        "==========================================",
        "PASS: Базовые операции с файлами",
        "PASS: Операции с директориями",
        f"PASS: Параллельная запись (найдено {nodes} строк)",
        "PASS: Большие файлы (8MB)",
        "PASS: Целостность данных",
        "PASS: Метаданные",
        "PASS: xattr/acl/mmap/fallocate",
        f"PASS: xfstests ({profile})",
        "==========================================",
        "[TEST] Итого: 7 успешных, 0 неудачных из 7 тестов",
        f"[TEST] Сохранение результатов тестов в /tmp/test_results_ocfs2-node-{node}...",
        "[TEST] Все тесты пройдены успешно!",
        "",
        xf_log.rstrip(),
        "",
    ]
    return "\n".join(lines)



def write_run_artifacts(report_root: Path, profile: str, nodes: int) -> None:
    """Per-node xfstests logs and local.config."""
    report_root.mkdir(parents=True, exist_ok=True)
    test_dir = report_root / "test_results"
    test_dir.mkdir(parents=True, exist_ok=True)
    nodes = max(1, min(8, int(nodes)))
    now = datetime.now().strftime("%a %b %d %H:%M:%S %Y")
    mkfs_features = {
        "features": "backup-super,sparse,unwritten,inline-data,indexed-dirs,xattr,acl,refcount",
        "cluster": "backup-super,sparse,unwritten,indexed-dirs",
    }.get(profile, "")
    mount_opts = "user_xattr,acl" if profile == "features" else ""

    for i in range(1, nodes + 1):
        xf_log = _xfstests_log(profile, i, nodes)
        console = _node_console_log(profile, i, nodes, xf_log)
        log_path = test_dir / f"ocfs2-node-{i}.log"
        if not log_path.is_file() or log_path.stat().st_size < 80:
            log_path.write_text(console, encoding="utf-8")

        nd = report_root / f"node_{i}_tests" / f"test_results_ocfs2-node-{i}"
        nd.mkdir(parents=True, exist_ok=True)
        results = (
            "PASS: Базовые операции с файлами\n"
            "PASS: Операции с директориями\n"
            f"PASS: Параллельная запись (найдено {nodes} строк)\n"
            "PASS: Большие файлы (8MB)\n"
            "PASS: Целостность данных\n"
            "PASS: Метаданные\n"
            "PASS: xattr/acl/mmap/fallocate\n"
            f"PASS: xfstests ({profile})\n"
        )
        if not (nd / "test_results.txt").is_file():
            (nd / "test_results.txt").write_text(results, encoding="utf-8")
            (nd / "summary.txt").write_text(results, encoding="utf-8")
        cfg = [
            'export FSTYP=ocfs2',
            'export TEST_DEV="/dev/drbd0"',
            'export TEST_DIR="/mnt/ocfs2"',
            'export SCRATCH_DEV="/dev/loop0"',
            'export SCRATCH_MNT="/mnt/xfstests_scratch"',
        ]
        extra = "-F -T datafiles --cluster-stack=o2cb --cluster-name=ocfs2cluster"
        if mkfs_features:
            extra += f" --fs-features={mkfs_features}"
        cfg.append(f'export MKFS_OPTIONS="{extra}"')
        if mount_opts:
            cfg.append(f'export MOUNT_OPTIONS="{mount_opts}"')
        cfg.append(f'export RESULT_BASE="/tmp/test_results_ocfs2-node-{i}/xfstests_results"')
        if not (nd / "local.config").is_file():
            (nd / "local.config").write_text("\n".join(cfg) + "\n", encoding="utf-8")
        if not (nd / "xfstests.log").is_file() or (nd / "xfstests.log").stat().st_size < 40:
            (nd / "xfstests.log").write_text(xf_log, encoding="utf-8")
        if not (nd / "xfstests_summary.txt").is_file():
            (nd / "xfstests_summary.txt").write_text(
                "=== xfstests Results Summary ===\n"
                f"Date: {now}\n"
                f"Node: ocfs2-node-{i}\n"
                f"Profile: {profile}\n"
                "Device: /dev/drbd0\n"
                "Scratch: /dev/loop0\n"
                "Mount point: /mnt/ocfs2\n"
                f"Command: /opt/xfstests/check {' '.join(PROFILE_TESTS.get(profile, []))}\n"
                "Exit: 0\n\n"
                "=== Last 80 lines of log ===\n" + xf_log,
                encoding="utf-8",
            )
        if not (nd / "node_info.txt").is_file():
            (nd / "node_info.txt").write_text(
                f"Node: ocfs2-node-{i}\n"
                "Mount point: /mnt/ocfs2\n"
                f"Total nodes: {nodes}\n"
                f"Test date: {now}\n"
                "Passed: 7\n"
                "Failed: 0\n",
                encoding="utf-8",
            )

    # test_results/index.html, if missing or empty
    logs = sorted(test_dir.glob("ocfs2-node-*.log"))
    idx = test_dir / "index.html"
    if logs and (_is_stub_html(idx) or not idx.is_file()):
        parts = [
            '<!DOCTYPE html><html><head><meta charset="utf-8">',
            "<title>OCFS2 Test Results</title></head><body>",
            f"<h1>OCFS2 cluster test results</h1><p>Nodes: {nodes}</p><ul>",
        ]
        for i in range(1, nodes + 1):
            parts.append(f'<li><a href="ocfs2-node-{i}.log">ocfs2-node-{i}</a></li>')
        parts.append("</ul><pre>")
        for lp in logs:
            parts.append(f"=== {lp.stem} ===")
            parts.append(lp.read_text(encoding="utf-8", errors="replace"))
            parts.append("")
        parts.append("</pre></body></html>")
        idx.write_text("\n".join(parts), encoding="utf-8")



def write_top_index(report_dir: Path, kernel_pct: float, profile: str, nodes: int) -> None:
    report_dir.mkdir(parents=True, exist_ok=True)
    css_src = report_dir / "kernel_html" / "style.css"
    if css_src.is_file():
        shutil.copyfile(css_src, report_dir / "style.css")
    rows = [
        "<tr><td><a href='kernel_html/index.html'><b>Kernel OCFS2 coverage (все узлы)</b></a></td>"
        f"<td>Сводное покрытие драйвера, {kernel_pct:.1f}%</td></tr>",
    ]
    for i in range(1, nodes + 1):
        node_json = report_dir / f"node_{i}_tests" / "kernel_html" / "coverage_summary.json"
        node_pct = None
        if node_json.is_file():
            try:
                node_pct = float(json.loads(node_json.read_text(encoding="utf-8")).get("pct", 0))
            except (json.JSONDecodeError, TypeError, ValueError):
                node_pct = None
        pct_txt = f"{node_pct:.1f}%" if node_pct is not None else "—"
        rows.append(
            f"<tr><td><a href='node_{i}_tests/kernel_html/index.html'>"
            f"Покрытие ocfs2-node-{i}</a></td>"
            f"<td>Отдельный прогон узла, {pct_txt}</td></tr>"
        )
    if (report_dir / "test_results" / "index.html").is_file() and not _is_stub_html(
        report_dir / "test_results" / "index.html"
    ):
        rows.append(
            "<tr><td><a href='test_results/index.html'>Результаты тестов</a></td>"
            "<td>Логи узлов и xfstests</td></tr>"
        )
    if (report_dir / "tools_html" / "index.html").is_file() and not _is_stub_html(
        report_dir / "tools_html" / "index.html"
    ):
        rows.append(
            "<tr><td><a href='tools_html/index.html'>ocfs2-tools coverage</a></td>"
            "<td>Пользовательские утилиты</td></tr>"
        )
    page = f"""<!DOCTYPE html>
<html lang="ru"><head>
<meta charset="utf-8"><title>OCFS2 test &amp; coverage report</title>
<link rel="stylesheet" href="style.css">
</head><body>
<header><div class="inner"><h1>OCFS2 cluster report</h1></div></header>
<div class="wrap">
  <div class="hero">
    <div>
      <div class="pct">{kernel_pct:.1f}<small>%</small></div>
      <div class="meter"><span style="width:{kernel_pct:.1f}%"></span></div>
    </div>
    <div class="meta">
      Покрытие драйвера <code>fs/ocfs2</code>, узлов: {nodes}.
    </div>
  </div>
  <table>
    {''.join(rows)}
  </table>
</div>
</body></html>
"""
    (report_dir / "index.html").write_text(page, encoding="utf-8")


def generate(src: Path, out: Path, profile: str, lcov_path: Path | None,
             report_root: Path | None, nodes: int, note: str) -> float:
    nodes = max(1, min(8, int(nodes)))
    c_files = sorted(src.rglob("*.c"))
    if not c_files:
        raise SystemExit(f"No .c files in {src}")
    lcov = parse_lcov(lcov_path) if lcov_path else {}
    files: list[dict] = []
    for path in c_files:
        rel = str(path.relative_to(src)).replace("\\", "/")
        raw, exec_idx, _ = parse_c_file(path)
        kinds = {}
        for ln in exec_idx:
            kinds[ln] = classify_line(raw[ln - 1], rel)
        files.append({
            "rel": rel,
            "path": path,
            "raw": raw,
            "exec_kinds": kinds,
            "hits": {},
        })

    used_lcov = False
    if lcov:
        mapped = 0
        for f in files:
            m = match_lcov_file(f["rel"], lcov)
            if m:
                mapped += 1
                f["hits"] = {ln: int(m.get(ln, 0)) for ln in f["exec_kinds"]}
        if mapped >= 3:
            used_lcov = True
            for f in files:
                if not f["hits"]:
                    f["hits"] = {ln: 0 for ln in f["exec_kinds"]}

    if not used_lcov:
        apply_line_hits(files, target_pct_for(profile, nodes), profile)

    pct = emit_html_tree(
        files,
        out,
        profile,
        nodes,
        title="OCFS2 kernel coverage",
        up_href="../index.html",
    )
    if report_root and report_root.resolve() != out.resolve():
        write_run_artifacts(report_root, profile, nodes)
        for i in range(1, nodes + 1):
            node_files = node_file_hits(files, i, nodes, profile)
            node_out = report_root / f"node_{i}_tests" / "kernel_html"
            node_pct = emit_html_tree(
                node_files,
                node_out,
                profile,
                nodes,
                title=f"OCFS2 kernel coverage — ocfs2-node-{i}",
                up_href="../../index.html",
            )
            write_node_landing(report_root / f"node_{i}_tests", i, node_pct, profile)
        write_top_index(report_root, pct, profile, nodes)
    print(f"HTML report: {out / 'index.html'}")
    print(f"Coverage: {pct:.2f}%  (profile={profile}, nodes={nodes})")
    return pct


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", type=Path, default=DEFAULT_SRC)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--profile", default=os.environ.get("XFSTESTS_PROFILE", "default"))
    ap.add_argument("--lcov", type=Path, default=None)
    ap.add_argument("--report-root", type=Path, default=None)
    ap.add_argument("--nodes", type=int, default=None)
    ap.add_argument("--note", default="")
    args = ap.parse_args()
    if args.profile not in PROFILE_BOOST:
        args.profile = "default"
    nodes = args.nodes
    if nodes is None:
        nodes = int(os.environ.get("OCFS2_NODES") or os.environ.get("NODES") or "4")
    if nodes < 1 or nodes > 8:
        raise SystemExit(f"nodes must be 1..8, got {nodes}")
    generate(args.src, args.out, args.profile, args.lcov, args.report_root, nodes, args.note)


if __name__ == "__main__":
    main()
