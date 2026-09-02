#!/usr/bin/env python3
"""Authenticated CBE Open Data portal download (licensed operator access).

Uses the registered operator account (kbo-open-data portal) to download the
latest Full and Update ZIP files. Credentials come only from the environment
or a private env file; they are never logged or committed. Downloaded data is
licensed material: store it privately, never commit it.

Env:
  KBO_OPEN_DATA_USERNAME  portal username
  KBO_OPEN_DATA_PASSWORD  portal password
Usage:
  python3 scripts/download_cbe_open_data.py --out /private/path [--date YYYY_MM_DD]
"""
import argparse
import hashlib
import http.cookiejar
import json
import os
import re
import sys
import urllib.parse
import urllib.request

BASE = "https://kbopub.economie.fgov.be"
LOGIN_URL = BASE + "/kbo-open-data/static/j_spring_security_check"
FILES_URL = BASE + "/kbo-open-data/affiliation/xml/?files"
UA = "brussels-wtf-cbe-open-data-operator/1.0"


def build_opener():
    jar = http.cookiejar.CookieJar()
    return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def fail(msg):
    print(f"FAIL: {msg}")
    raise SystemExit(1)


def login(opener, user, password):
    data = urllib.parse.urlencode(
        {"j_username": user, "j_password": password}
    ).encode()
    request = urllib.request.Request(
        LOGIN_URL, data=data, headers={"User-Agent": UA}
    )
    try:
        with opener.open(request, timeout=60) as response:
            body = response.read().decode("utf-8", "replace")
            final = response.geturl()
    except Exception as error:  # noqa: BLE001
        fail(f"login request error: {error}")
    if "j_spring_security_check" in final or "j_password" in body:
        fail("login rejected; check credentials")
    return body if "?files" in final else None


def fetch(opener, url):
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    with opener.open(request, timeout=120) as response:
        return response.read(), response.geturl()


def listing(opener):
    body, final = fetch(opener, FILES_URL)
    text = body.decode("utf-8", "replace")
    if "j_password" in text:
        fail("not authenticated on the files page")
    links = sorted(set(re.findall(r'href="([^"]+\.zip)"', text, re.I)))
    if not links:
        fail("no .zip links found on the files page")
    return text, links


def pick(links, want_full, want_update, date):
    def base_name(link):
        return urllib.parse.unquote(link.rsplit("/", 1)[-1])

    def matches(link):
        name = base_name(link)
        ok_date = date is None or date in name
        return ok_date

    fulls = [l for l in links if "Full" in base_name(l) and matches(l)]
    updates = [l for l in links if "Update" in base_name(l) and matches(l)]
    chosen = []
    if want_full:
        if not fulls:
            fail("no Full file matched")
        chosen.append(fulls[-1])
    if want_update:
        if not updates:
            fail("no Update file matched")
        chosen.append(updates[-1])
    return chosen


def download(opener, link, out_dir):
    name = urllib.parse.unquote(link.rsplit("/", 1)[-1])
    url = link if link.startswith("http") else urllib.parse.urljoin(FILES_URL, link)
    body, final = fetch(opener, url)
    if len(body) < 1000 or not body[:2] == b"PK":
        fail(f"{name}: response is not a plausible zip ({len(body)} bytes)")
    path = os.path.join(out_dir, name)
    with open(path, "wb") as handle:
        handle.write(body)
    digest = hashlib.sha256(body).hexdigest()
    print(f"OK {name}: {len(body)} bytes sha256={digest}")
    return {"file": name, "url": final, "bytes": len(body), "sha256": digest}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True, help="private output directory")
    parser.add_argument("--date", default=None, help="YYYY_MM_DD filter")
    parser.add_argument(
        "--no-full", action="store_true", help="skip the Full snapshot"
    )
    parser.add_argument(
        "--no-update", action="store_true", help="skip the Update file"
    )
    parser.add_argument("--env-file", default=None, help="private env file path")
    args = parser.parse_args()

    if args.env_file:
        with open(args.env_file) as handle:
            for line in handle:
                if "=" in line and not line.strip().startswith("#"):
                    key, _, value = line.strip().partition("=")
                    os.environ.setdefault(key.strip(), value.strip())
    user = os.environ.get("KBO_OPEN_DATA_USERNAME")
    password = os.environ.get("KBO_OPEN_DATA_PASSWORD")
    if not user or not password:
        fail("set KBO_OPEN_DATA_USERNAME and KBO_OPEN_DATA_PASSWORD")

    os.makedirs(args.out, exist_ok=True)
    opener = build_opener()
    login(opener, user, password)
    _, links = listing(opener)
    chosen = pick(links, not args.no_full, not args.no_update, args.date)
    results = [download(opener, link, args.out) for link in chosen]
    manifest = os.path.join(args.out, "download-manifest.json")
    with open(manifest, "w") as handle:
        json.dump(
            {"retrieved_at_utc": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(), "files": results},
            handle,
            indent=2,
        )
    print(f"OK manifest {manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
