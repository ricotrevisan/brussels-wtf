#!/usr/bin/env python3
"""Credential-free, byte-free access check for the Ixelles mandate list (issue #43).

This resolves the authoritative index page, the exact latest ``Liste des mandats``
document and its version/year signals, and proves a parseable role row exists. It
never writes source bytes to disk and never prints personal data (names, national
numbers, addresses, signatures, or remuneration amounts). All PDF bytes stay in
memory and are discarded when the process exits. Standard library only.

Usage:
  python3 scripts/check_ixelles_mandate_access.py              # index + HEAD version signals
  python3 scripts/check_ixelles_mandate_access.py --fetch-document  # add gated in-memory body parse
  python3 scripts/check_ixelles_mandate_access.py --self-test  # offline helper tests
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
import unicodedata
import zlib
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlparse
from urllib.request import Request, urlopen

INDEX_URL = (
    "https://www.ixelles.be/site/"
    "773-Rapports-annuels-Remunerations-et-avantages?langue=fr"
)
INDEX_HOST = "www.ixelles.be"
USER_AGENT = "brussels-wtf-mandate-access-preflight/1.0 (+research spike)"
MANDATE_LINK_RE = re.compile(r"mandats-(\d{4})\.pdf", re.IGNORECASE)

# Fixed form section labels are template vocabulary, not personal data.
BOILERPLATE_MARKERS = (
    "liste des mandats, fonctions et fonctions",
    "cellule transparence",
    "vade-mecum",
    "modele de formulaire",
    "declaration faite en execution",
    "arrete d'execution",
    "ordonnance conjointe",
    "y compris pour ceux",
    "compris pour ceux",
    "numero national",
    "nom :",
    "prenom",
    "adresse",
)


def parse_latest_mandate_link(html_text: str, base_url: str):
    """Return ``(year, absolute_url)`` for the newest ``mandats-YYYY.pdf`` link.

    Returns ``None`` when the index page has no parseable mandate list.
    """
    links = re.findall(r'<a[^>]+href="([^"]+)"[^>]*>', html_text, re.IGNORECASE)
    best = None
    for href in links:
        match = MANDATE_LINK_RE.search(href)
        if not match:
            continue
        year = int(match.group(1))
        if best is None or year > best[0]:
            best = (year, urljoin(base_url, href))
    return best


def _normalize(text: str) -> str:
    """Strip accents and non-letters so OCR variants compare as letters only."""
    decomposed = unicodedata.normalize("NFKD", text.strip().lower())
    without_accents = "".join(c for c in decomposed if not unicodedata.combining(c))
    return re.sub(r"[^a-z]", "", without_accents)


def _header_kind(line: str):
    """Classify a standalone section header line, or ``None``."""
    norm = _normalize(line)
    if not norm:
        return None
    if norm == "mandats" or (
        norm.startswith("mandat") and len(norm) <= 9 and "fonction" not in norm
    ):
        return "MANDATS"
    if norm == "fonctionsderivees" or (
        "fonction" in norm and "derive" in norm and len(norm) <= 22
    ):
        return "DERIVEES"
    if norm == "fonctions" or (
        norm.startswith("fonction") and len(norm) <= 11 and "derive" not in norm
    ):
        return "FONCTIONS"
    return None


def _is_boilerplate(line: str) -> bool:
    lowered = line.strip().lower()
    if not lowered:
        return True
    if len(_normalize(lowered)) < 2:
        return True
    return any(marker in lowered for marker in BOILERPLATE_MARKERS)


def _section_page_signals(page_text: str) -> dict:
    """Structural signals for one page/segment; never returns any row content."""
    lines = page_text.splitlines()
    idx_mandats = None
    idx_fonctions = None
    has_derivees = False
    for i, line in enumerate(lines):
        kind = _header_kind(line)
        if kind == "MANDATS" and idx_mandats is None:
            idx_mandats = i
        elif kind == "FONCTIONS" and idx_mandats is not None and idx_fonctions is None:
            idx_fonctions = i
        elif kind == "DERIVEES":
            has_derivees = True
    filled_rows = 0
    if idx_mandats is not None:
        lo = idx_mandats + 1
        hi = idx_fonctions if idx_fonctions is not None else len(lines)
        for line in lines[lo:hi]:
            if not _is_boilerplate(line):
                filled_rows += 1
    return {
        "has_mandats": idx_mandats is not None,
        "has_fonctions": idx_fonctions is not None,
        "has_derivees": has_derivees,
        "filled_mandate_rows": filled_rows,
    }


def role_row_signals(page_texts):
    """Aggregate non-personal structural signals across all pages/segments."""
    counts = {
        "page_count": len(page_texts),
        "pages_with_mandats_header": 0,
        "pages_with_fonctions_header": 0,
        "pages_with_derivees_header": 0,
        "pages_with_filled_mandate_row": 0,
        "pages_with_all_three_headers": 0,
    }
    for text in page_texts:
        sig = _section_page_signals(text)
        counts["pages_with_mandats_header"] += int(sig["has_mandats"])
        counts["pages_with_fonctions_header"] += int(sig["has_fonctions"])
        counts["pages_with_derivees_header"] += int(sig["has_derivees"])
        if sig["has_mandats"] and sig["filled_mandate_rows"] > 0:
            counts["pages_with_filled_mandate_row"] += 1
        if sig["has_mandats"] and sig["has_fonctions"] and sig["has_derivees"]:
            counts["pages_with_all_three_headers"] += 1
    return counts


# --- Minimal standard-library PDF text-layer extraction (in memory only) ---

TM_RE = re.compile(rb"(?:(?:[-+]?(?:\d+\.?\d*|\.\d+))\s+){6}Tm")
NUM_RE = re.compile(rb"[-+]?(?:\d+\.?\d*|\.\d+)")
WORD_RE = re.compile(rb"\(((?:[^()\\]|\\.)*)\)\s*Tj")


def _decode_pdf_string(raw: bytes) -> str:
    """Decode a PDF literal string's octal escapes and escaped parentheses."""
    out = []
    i = 0
    n = len(raw)
    while i < n:
        char = raw[i]
        if char == 0x5C:  # backslash escape
            if i + 1 < n:
                nxt = raw[i + 1]
                if nxt in b"()\\":
                    out.append(chr(nxt))
                    i += 2
                    continue
                if nxt in b"01234567":
                    j = i + 1
                    digits = []
                    while j < n and len(digits) < 3 and raw[j] in b"01234567":
                        digits.append(raw[j])
                        j += 1
                    out.append(chr(int(bytes(digits), 8)))
                    i = j
                    continue
            i += 1
            continue
        out.append(chr(char))
        i += 1
    return "".join(out)


def _stream_to_lines(decoded_stream: bytes):
    """Rebuild approximate text lines from one PDF content stream."""
    events = []
    for match in TM_RE.finditer(decoded_stream):
        nums = NUM_RE.findall(match.group(0))
        if len(nums) == 6:
            try:
                y_position = float(nums[5])
            except ValueError:
                continue
            events.append((match.end(), "y", y_position))
    for match in WORD_RE.finditer(decoded_stream):
        events.append((match.start(), "w", _decode_pdf_string(match.group(1))))
    events.sort(key=lambda event: event[0])

    lines = []
    current = []
    current_y = None

    def flush():
        nonlocal current
        if current:
            lines.append(" ".join(current).strip())
            current = []

    for _, kind, value in events:
        if kind == "y":
            if current_y is None or abs(value - current_y) > 1.0:
                flush()
            current_y = value
        else:
            if current_y is None:
                current_y = 0.0
            current.append(value)
    flush()
    return lines


def extract_page_texts(pdf_bytes: bytes):
    """Extract an approximate per-page text layer using only the standard library."""
    texts = []
    for match in re.finditer(rb"stream\r?\n", pdf_bytes):
        start = match.end()
        end = pdf_bytes.find(b"endstream", start)
        if end == -1:
            continue
        raw = pdf_bytes[start:end]
        try:
            decoded = zlib.decompress(raw.rstrip(b"\r\n"))
        except zlib.error:
            decoded = raw
        lines = _stream_to_lines(decoded)
        if lines:
            texts.append("\n".join(lines))
    return texts


def fetch(url: str, timeout: int = 60, method: str = "GET", headers=None):
    request = Request(url, headers=headers or {}, method=method)
    return urlopen(request, timeout=timeout)


def live_check(fetch_document: bool) -> int:
    failed = False

    def report(ok: bool, message: str) -> bool:
        nonlocal failed
        print(f"{'OK' if ok else 'FAIL'} {message}")
        failed = failed or not ok
        return ok

    # 1. Authoritative index page (in memory only).
    try:
        with fetch(INDEX_URL, headers={"User-Agent": USER_AGENT}) as response:
            index_html = response.read().decode("utf-8", "replace")
            index_status = response.status
            index_final = response.geturl()
    except (HTTPError, URLError, TimeoutError) as error:
        print(f"FAIL index page: {error}")
        return 1
    report(index_status == 200, f"index page HTTP {index_status}")
    report(
        urlparse(index_final).hostname == INDEX_HOST,
        f"index served by authoritative domain ({urlparse(index_final).hostname})",
    )

    # 2. Exact document/year from the index.
    resolved = parse_latest_mandate_link(index_html, INDEX_URL)
    if not resolved:
        print("FAIL no mandats-YYYY.pdf link found on the index page")
        return 1
    year, doc_url = resolved
    report(True, f"resolved mandate list year={year} at {doc_url}")

    # 3. Version signals via HEAD (no body).
    try:
        with fetch(doc_url, method="HEAD", headers={"User-Agent": USER_AGENT}) as head:
            status = head.status
            content_type = head.headers.get_content_type()
            length = head.headers.get("Content-Length")
            etag = head.headers.get("ETag")
            last_modified = head.headers.get("Last-Modified")
            final_url = head.geturl()
    except (HTTPError, URLError, TimeoutError) as error:
        print(f"FAIL document HEAD: {error}")
        return 1
    report(status == 200 and content_type == "application/pdf",
           f"document HEAD HTTP {status} {content_type}")
    report(bool(etag), f"ETag present ({etag})")
    report(bool(last_modified), f"Last-Modified present ({last_modified})")
    report(final_url.rstrip("/") == doc_url.rstrip("/"),
           f"document locator stable (final URL {final_url})")

    if not fetch_document:
        print("SKIP document body: the download path is robots-disallowed, so the default")
        print("      check stops at the HEAD version signals above and does not fetch bytes.")
        print("      Pass --fetch-document to fetch the body into memory (and discard it).")
        print("BLOCKED: document confirmed and linkable, but no open-data licence or crawl permission was found;")
        print("         automated retrieval/republication stays blocked pending written terms from the municipality.")
        return 1 if failed else 0

    # 4. Full bytes in memory for the version hash and the parseable row.
    try:
        with fetch(doc_url, headers={"User-Agent": USER_AGENT}) as body:
            pdf_bytes = body.read()
            body_status = body.status
    except (HTTPError, URLError, TimeoutError) as error:
        print(f"FAIL document GET: {error}")
        return 1
    report(body_status == 200, f"document GET HTTP {body_status}")
    report(bool(length) and str(len(pdf_bytes)) == str(length),
           f"Content-Length matches body ({len(pdf_bytes)} bytes)")
    digest = hashlib.sha256(pdf_bytes).hexdigest()
    report(True, f"version identity sha256={digest} (bytes held in memory, not written)")

    # 5. Parseable role row, reporting structure only.
    try:
        page_texts = extract_page_texts(pdf_bytes)
        signals = role_row_signals(page_texts)
    except Exception as error:  # noqa: BLE001
        print(f"FAIL text-layer parse: {error}")
        return 1
    report(signals["page_count"] >= 1,
           f"document text layer spans {signals['page_count']} segments")
    report(signals["pages_with_mandats_header"] >= 1,
           f"{signals['pages_with_mandats_header']} segments carry the MANDATS header")
    report(signals["pages_with_derivees_header"] >= 1,
           f"{signals['pages_with_derivees_header']} segments carry the FONCTIONS DERIVEES header")
    report(signals["pages_with_filled_mandate_row"] >= 1,
           f"{signals['pages_with_filled_mandate_row']} segments contain a parseable mandate row")

    print("BLOCKED: document confirmed and linkable, but no open-data licence or crawl permission was found;")
    print("         automated retrieval/republication stays blocked pending written terms from the municipality.")
    return 1 if failed else 0


def self_test() -> int:
    """Offline tests for the pure helpers (no network, no source bytes)."""
    failures = []

    def check(condition: bool, message: str):
        if not condition:
            failures.append(message)
        print(f"{'OK' if condition else 'FAIL'} {message}")

    html = (
        '<a href="fr/download/transparence/mandats-2023.pdf">2023</a>'
        '<a href="fr/download/transparence/rapport-annuel-transparence-2025.pdf">x</a>'
        '<a href="fr/download/transparence/mandats-2024.pdf">2024</a>'
    )
    check(parse_latest_mandate_link(html, INDEX_URL) == (
        2024,
        "https://www.ixelles.be/site/fr/download/transparence/mandats-2024.pdf",
    ), "latest mandate link resolves to 2024")

    check(parse_latest_mandate_link("<p>no links</p>", INDEX_URL) is None,
          "index without mandate links resolves to None")

    blank = (
        "1. Liste des mandats, fonctions et fonctions derivees\n"
        "MANDATS\n"
        "FONCTIONS\n"
        "FONCTIONS DERIVEES"
    )
    filled = (
        "1. Liste des mandats, fonctions et fonctions derivees\n"
        "MANDATS\n"
        "Premier Echevin et Officier de l'Etat Civil\n"
        "FONCTIONS\n"
        "FONCTIONS DERIVEES"
    )
    check(role_row_signals([blank, filled])["pages_with_filled_mandate_row"] == 1,
          "filled declaration page yields one parseable mandate row")
    check(role_row_signals([blank, blank])["pages_with_filled_mandate_row"] == 0,
          "blank template pages yield no parseable mandate row")
    check(_normalize("FONCTIONS DÉRIVÉES") == "fonctionsderivees",
          "accented section header normalizes without accents")
    check(_header_kind("FONCTIONS DÉRIVÉES") == "DERIVEES",
          "accented derived-function header is detected")
    check(_decode_pdf_string(b"D\\351cembre 2024\\)") == "Décembre 2024)",
          "PDF octal and parenthesis escapes decode")

    if failures:
        print(f"{len(failures)} self-test failure(s)")
        return 1
    print("all self-tests passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true", help="offline helper tests")
    parser.add_argument(
        "--fetch-document",
        action="store_true",
        help="fetch the PDF body into memory (discarded) for the digest and role-row parse",
    )
    args = parser.parse_args()
    return self_test() if args.self_test else live_check(args.fetch_document)


if __name__ == "__main__":
    raise SystemExit(main())
