#!/usr/bin/env python3

import argparse
import concurrent.futures
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
RENDERER = ROOT / "src" / "RBXTTF.lua"
FAMILY = ROOT / "src" / "RBXTTFFamily.lua"
RUNNER = ROOT / "tests" / "mass_font_runner.lua"
EXTENSIONS = {".ttf", ".otf"}


def find_fonts(paths):
    found = set()
    for raw_path in paths:
        path = pathlib.Path(raw_path).expanduser().resolve()
        if path.is_file() and path.suffix.lower() in EXTENSIONS:
            found.add(path)
        elif path.is_dir():
            for candidate in path.rglob("*"):
                if candidate.is_file() and candidate.suffix.lower() in EXTENSIONS:
                    found.add(candidate.resolve())
    return sorted(found)


def request_json(url):
    headers = {"User-Agent": "RBXTTF-mass-test"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
        return json.load(response)


def download_google_fonts(limit, cache_dir, workers):
    tree = request_json("https://api.github.com/repos/google/fonts/git/trees/main?recursive=1")
    candidates = sorted(
        item["path"]
        for item in tree.get("tree", [])
        if item.get("type") == "blob"
        and pathlib.PurePosixPath(item["path"]).suffix.lower() == ".ttf"
        and item["path"].startswith(("ofl/", "apache/", "ufl/"))
    )
    if tree.get("truncated"):
        raise RuntimeError("Google Fonts tree response was truncated")
    if not candidates:
        raise RuntimeError("Google Fonts returned no TTF files")

    limit = min(limit, len(candidates))
    if limit < len(candidates):
        step = len(candidates) / limit
        candidates = [candidates[int(index * step)] for index in range(limit)]

    cache_dir.mkdir(parents=True, exist_ok=True)

    def download(path):
        digest = hashlib.sha1(path.encode()).hexdigest()[:12]
        target = cache_dir / f"{digest}-{pathlib.PurePosixPath(path).name}"
        if target.exists() and target.stat().st_size > 1000:
            return target
        url = "https://raw.githubusercontent.com/google/fonts/main/" + path
        request = urllib.request.Request(url, headers={"User-Agent": "RBXTTF-mass-test"})
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read()
        if len(data) < 1000:
            raise RuntimeError(f"short download: {path}")
        target.write_bytes(data)
        return target

    fonts = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(download, path): path for path in candidates}
        for future in concurrent.futures.as_completed(futures):
            fonts.append(future.result())
    return sorted(fonts)


def run_font(lua, font, timeout):
    started = time.monotonic()
    command = [
        lua,
        str(RUNNER),
        str(RENDERER),
        str(FAMILY),
        str(font),
    ]
    try:
        process = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return {
            "path": str(font),
            "status": "TIMEOUT",
            "seconds": time.monotonic() - started,
            "message": f"exceeded {timeout}s",
        }

    lines = [line for line in process.stdout.splitlines() if line]
    fields = lines[-1].split("\t") if lines else ["FAIL", "no runner output"]
    status = fields[0]
    result = {
        "path": str(font),
        "status": status,
        "seconds": time.monotonic() - started,
    }

    if status == "PASS" and len(fields) >= 7:
        result.update({
            "family": fields[1],
            "full_name": fields[2],
            "weight": int(fields[3]),
            "style": fields[4],
            "glyphs": int(fields[5]),
            "cpu_seconds": float(fields[6]),
        })
    else:
        result["message"] = "\n".join(
            value for value in (process.stderr.strip(), "\n".join(fields[1:])) if value
        )
    if process.returncode != 0 and status != "FAIL":
        result["status"] = "FAIL"
        result["message"] = process.stderr.strip() or f"exit code {process.returncode}"
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="*", help="font files or directories")
    parser.add_argument("--google", type=int, default=0, metavar="COUNT")
    parser.add_argument("--cache-dir", default="tests/.font-corpus")
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 1))
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--lua", default="lua")
    parser.add_argument("--json", default="tests/mass-results.json")
    args = parser.parse_args()

    fonts = find_fonts(args.paths)
    if args.google:
        fonts.extend(download_google_fonts(
            args.google,
            (ROOT / args.cache_dir).resolve() if not pathlib.Path(args.cache_dir).is_absolute() else pathlib.Path(args.cache_dir),
            args.jobs,
        ))
    fonts = sorted(set(fonts))
    if args.limit:
        fonts = fonts[:args.limit]
    if not fonts:
        parser.error("no fonts found; pass a path or use --google COUNT")

    print(f"testing {len(fonts)} fonts with {args.jobs} workers")
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(run_font, args.lua, font, args.timeout): font for font in fonts}
        for index, future in enumerate(concurrent.futures.as_completed(futures), 1):
            result = future.result()
            results.append(result)
            print(f"[{index:>4}/{len(fonts)}] {result['status']:<7} {pathlib.Path(result['path']).name} ({result['seconds']:.2f}s)")

    results.sort(key=lambda item: item["path"])
    counts = {
        status: sum(result["status"] == status for result in results)
        for status in ("PASS", "SKIP", "FAIL", "TIMEOUT")
    }
    report = {
        "counts": counts,
        "font_count": len(results),
        "results": results,
    }
    report_path = pathlib.Path(args.json)
    if not report_path.is_absolute():
        report_path = ROOT / report_path
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n")

    print()
    print(" ".join(f"{key.lower()}={value}" for key, value in counts.items()))
    print(f"report={report_path}")

    failures = [result for result in results if result["status"] in {"FAIL", "TIMEOUT"}]
    if failures:
        print("\nfailures:")
        for result in failures:
            print(f"- {result['path']}: {result.get('message', result['status'])}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

