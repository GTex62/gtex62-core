#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
import tomllib
from datetime import datetime, timezone
from pathlib import Path

HOME = Path(os.path.expanduser("~"))
XDG_CACHE_HOME = Path(os.getenv("XDG_CACHE_HOME") or (HOME / ".cache"))
CONFIG_ROOT = Path(os.getenv("GTEX62_CONFIG_DIR") or os.getenv("GTEX62_CONKY_CONFIG_DIR") or (HOME / ".config" / "gtex62-core"))
CACHE_ROOT = Path(os.getenv("GTEX62_CACHE_DIR") or os.getenv("GTEX62_CONKY_CACHE_DIR") or (XDG_CACHE_HOME / "gtex62-core"))
PROFILE_ID = sys.argv[1] if len(sys.argv) > 1 else "default"
PROFILE_TOML = CONFIG_ROOT / "profiles" / "github" / f"{PROFILE_ID}.toml"
SITE_TOML = CONFIG_ROOT / "site.toml"
OUT_DIR = CACHE_ROOT / "shared" / "github" / PROFILE_ID
TMP_DIR = CACHE_ROOT / "tmp"
CURRENT_JSON = OUT_DIR / "current.json"
STATUS_JSON = OUT_DIR / "status.json"
LOG_FILE = OUT_DIR / "fetch.log"


def load_toml(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except Exception:
        return {}


def load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def atomic_write(path: Path, content: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = TMP_DIR / (path.name + ".tmp")
    tmp.parent.mkdir(parents=True, exist_ok=True)
    tmp.write_text(content, encoding="utf-8")
    tmp.replace(path)


def write_status(state: str, note: str = ""):
    atomic_write(STATUS_JSON, json.dumps({
        "state": state,
        "profile": PROFILE_ID,
        "collector": "github",
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "note": note,
    }, indent=2) + "\n")


def repo_slug(repo: str) -> str:
    return "".join(ch if ch.isalnum() else "_" for ch in repo)


def fetch_json(cmd: list) -> dict:
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def gh_created_at(repo: str):
    try:
        out = subprocess.run(
            ["gh", "api", f"repos/{repo}", "--jq", ".created_at"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        return out or None
    except Exception:
        return None


def read_registry(registry_path: Path) -> list:
    if not registry_path.exists():
        return []
    try:
        payload = json.loads(registry_path.read_text(encoding="utf-8"))
    except Exception:
        return []
    repos = payload.get("repos") if isinstance(payload, dict) else payload
    if not isinstance(repos, list):
        return []
    out = []
    for item in repos:
        if isinstance(item, str) and item.strip():
            out.append({"repo": item.strip(), "note": None})
        elif isinstance(item, dict):
            repo = str(item.get("repo") or "").strip()
            if repo:
                note = str(item.get("note") or "").strip() or None
                out.append({"repo": repo, "note": note})
    return out


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    TMP_DIR.mkdir(parents=True, exist_ok=True)

    profile = load_toml(PROFILE_TOML)

    if profile and not profile.get("enabled", True):
        write_status("disabled", "profile disabled")
        return 0

    request_cfg = profile.get("request", {})
    repos_cfg = profile.get("repos", {})
    cache_ttl = int(request_cfg.get("cache_ttl_sec", 21600))

    registry_path_str = repos_cfg.get("registry_path") or ""
    if registry_path_str:
        registry_path = Path(os.path.expanduser(registry_path_str))
    else:
        registry_path = HOME / ".config" / "conky" / "github-traffic-repos.json"

    existing = load_json(CURRENT_JSON)
    last_updated = int(existing.get("updated_at_epoch") or 0)
    now = int(time.time())
    force = str(os.getenv("GITHUB_TRAFFIC_FORCE") or "").strip().lower() in ("1", "true", "yes", "on")
    if (not force) and last_updated and (now - last_updated) < cache_ttl:
        return 0

    repos = read_registry(registry_path)
    extra = os.getenv("GITHUB_TRAFFIC_REPOS", "")
    for repo in extra.split(","):
        repo = repo.strip()
        if repo and not any(item.get("repo") == repo for item in repos):
            repos.append({"repo": repo, "note": None})
    repos = [r for r in repos if r.get("repo")]

    if not repos:
        write_status("error", "no repos configured")
        return 1

    merged_repos = (existing.get("repos") or {}).copy()
    errors = []

    for item in repos:
        repo = item["repo"]
        note = item.get("note")
        try:
            payload = fetch_json(["gh", "api", f"repos/{repo}/traffic/clones"])
        except Exception as exc:
            msg = f"{datetime.now().astimezone().isoformat()} WARN fetch failed for {repo}: {exc}"
            with LOG_FILE.open("a", encoding="utf-8") as fh:
                fh.write(msg + "\n")
            errors.append(repo)
            continue

        existing_repo = merged_repos.get(repo) or {}
        history_days = dict(existing_repo.get("history_days") or {})
        for entry in payload.get("clones") or []:
            ts = str(entry.get("timestamp") or "")
            day = ts[:10]
            if not day:
                continue
            history_days[day] = {
                "timestamp": ts,
                "count": int(entry.get("count") or 0),
                "uniques": int(entry.get("uniques") or 0),
            }

        lifetime_count = sum(int(v.get("count") or 0) for v in history_days.values())
        repo_created_at = existing_repo.get("repo_created_at") or gh_created_at(repo)
        complete_lifetime = existing_repo.get("complete_lifetime")
        if complete_lifetime is None and repo_created_at:
            try:
                created_dt = datetime.strptime(repo_created_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                complete_lifetime = (datetime.now(timezone.utc) - created_dt).days < 14
            except Exception:
                complete_lifetime = None

        merged_repos[repo] = {
            "source": "github_api_traffic_clones",
            "window_count": int(payload.get("count") or 0),
            "window_uniques": int(payload.get("uniques") or 0),
            "lifetime_count": lifetime_count,
            "complete_lifetime": complete_lifetime,
            "repo_created_at": repo_created_at,
            "note": note,
            "history_days": history_days,
        }
        total_text = f"GH{lifetime_count:04d}" if lifetime_count < 10000 else f"GH{lifetime_count}"
        atomic_write(OUT_DIR / f"{repo_slug(repo)}.total", total_text + "\n")

    atomic_write(CURRENT_JSON, json.dumps({
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "updated_at_epoch": now,
        "profile": PROFILE_ID,
        "repos": merged_repos,
    }, indent=2, sort_keys=True) + "\n")

    if errors:
        write_status("error", f"fetch failed for: {', '.join(errors)}")
    else:
        write_status("ok")

    return 0


if __name__ == "__main__":
    sys.exit(main())
