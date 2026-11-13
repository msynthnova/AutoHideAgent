#!/usr/bin/env python3
"""Publish via GitHub with checked responses and no credentials in output/argv."""
import json
import base64
import os
from pathlib import Path
import subprocess
import sys
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent
REPO = "msynthnova/AutoHideAgent"
API = f"https://api.github.com/repos/{REPO}"

def token():
    value = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if not value:
        result = subprocess.run(["git", "credential-osxkeychain", "get"],
            input="protocol=https\nhost=github.com\n\n", text=True, capture_output=True)
        value = next((line.partition("=")[2] for line in result.stdout.splitlines() if line.startswith("password=")), None)
    if not value:
        result = subprocess.run(["gh", "auth", "token"], text=True, capture_output=True)
        if result.returncode == 0:
            value = result.stdout.strip()
    if not value:
        raise RuntimeError("GitHub credentials unavailable; run gh auth login")
    return value

TOKEN = token()

def request(method, url, payload=None, content_type="application/json"):
    data = json.dumps(payload).encode() if isinstance(payload, dict) else payload
    req = Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {TOKEN}", "Accept": "application/vnd.github+json",
        "Content-Type": content_type, "User-Agent": "AutoHideAgent-release"})
    try:
        with urlopen(req, timeout=120) as response:
            return json.load(response)
    except HTTPError as error:
        raise RuntimeError(f"GitHub {method} failed with HTTP {error.code}") from None

mode, version = sys.argv[1:3]
if mode == "preflight":
    repo = request("GET", API)
    if not repo.get("permissions", {}).get("push"):
        raise RuntimeError("GitHub token cannot publish this repository")
    releases = request("GET", API + "/releases?per_page=100")
    if any(r["tag_name"] == f"v{version}" for r in releases):
        raise RuntimeError(f"Release v{version} already exists")
    print("GitHub publishing access verified.")
elif mode == "upload":
    build, description, checksum = sys.argv[3:6]
    body = (f"## AutoHideAgent v{version}\n\n{description}\n\n"
            f"### Verification\n- Signed with Developer ID Application\n"
            f"- Notarized by Apple; ticket stapled\n- SHA-256: `{checksum}`\n")
    release = request("POST", API + "/releases", {"tag_name": f"v{version}",
        "name": f"AutoHideAgent v{version}", "body": body, "draft": True})
    files = [ROOT / "dist" / f"AutoHideAgent-macOS-v{version}.zip",
             ROOT / "dist" / f"AutoHideAgent-macOS-v{version}.zip.sha256"]
    files += sorted((ROOT / "dist").glob(f"AutoHideAgent{build}-*.delta"))
    for path in files:
        result = request("POST", release["upload_url"].split("{")[0] + "?name=" + quote(path.name),
                         path.read_bytes(), "application/octet-stream")
        if result.get("state") != "uploaded" or result.get("size") != path.stat().st_size:
            raise RuntimeError(f"Upload verification failed: {path.name}")
        print(f"Uploaded {path.name}")
elif mode == "push":
    checkout, ref = sys.argv[3:5]
    environment = os.environ.copy()
    index = int(environment.get("GIT_CONFIG_COUNT", "0"))
    environment["GIT_CONFIG_COUNT"] = str(index + 1)
    environment[f"GIT_CONFIG_KEY_{index}"] = "http.https://github.com/.extraheader"
    header = base64.b64encode(f"x-access-token:{TOKEN}".encode()).decode()
    environment[f"GIT_CONFIG_VALUE_{index}"] = f"AUTHORIZATION: basic {header}"
    subprocess.run(["git", "-C", checkout, "push", "origin", ref], env=environment, check=True)
elif mode == "publish":
    releases = request("GET", API + "/releases?per_page=100")
    release = next(r for r in releases if r["tag_name"] == f"v{version}")
    result = request("PATCH", release["url"], {"draft": False})
    if result["draft"]:
        raise RuntimeError("Release is still a draft")
    print(result["html_url"])
else:
    raise ValueError("Unknown release action")
