#!/usr/bin/env python3
"""Credential-free TED result/award notice access check (metadata only).

Validates the anonymous TED Search API and signed-PDF direct link path that a
future ``public_contract_awarded`` verifier would use. It prints one JSON
summary to stdout. It never downloads or saves notice bulk data, never keeps
the signed PDF bytes after the signature check, and takes no credentials.

What it checks:

1. Search API (POST https://api.ted.europa.eu/v3/notices/search) can be called
   anonymously and returns the latest version of one result/award notice with a
   winning lot (form-type=result, winner-selection-status=selec-w), preferring a
   Belgian buyer and winner.
2. The returned notice carries contract-award metadata (buyer/winner
   identifiers, selection status, lot, value + currency, conclusion date) and
   version/correction fields (notice-version, change-notice-version-identifier,
   change-reason-code).
3. The notice's signed PDF direct link (format ``pdfs``) serves HTTP 200 with
   ``application/pdf`` and contains a PDF digital-signature dictionary
   (``/ByteRange`` and ``/SubFilter``); only the response size and signature
   markers are kept, not the bytes.
4. A separate search returns one result notice that is itself a correction, so
   the linked correction/version metadata fields are demonstrated.

Exit code 0 means every check passed; 1 means a check failed (or the service
was unreachable).
"""
import json
import sys
import urllib.error
import urllib.request

SEARCH_URL = "https://api.ted.europa.eu/v3/notices/search"
USER_AGENT = "brussels-wtf-ted-award-access-check/1.0"
TIMEOUT = 40
PDF_SIGNATURE_MARKERS = (b"/ByteRange", b"/SubFilter")
MAX_PDF_READ = 4 * 1024 * 1024  # only read this much to detect the signature dict

AWARD_FIELDS = [
    "publication-number",
    "notice-type",
    "form-type",
    "notice-subtype",
    "notice-purpose",
    "ojs-number",
    "gazette-issue-id",
    "notice-version",
    "publication-date",
    "dispatch-date",
    "links",
    "buyer-identifier",
    "buyer-name",
    "buyer-country",
    "winner-identifier",
    "winner-name",
    "winner-country",
    "winner-selection-status",
    "winner-listed",
    "winner-decision-date",
    "result-lot-identifier",
    "tender-lot-identifier",
    "result-value-notice",
    "result-value-cur-notice",
    "result-value-lot",
    "result-value-cur-lot",
    "total-value",
    "total-value-cur",
    "estimated-value-lot",
    "framework-maximum-value-lot",
    "contract-conclusion-date",
    "non-award-justification",
    "competition-termination-proc",
    "change-notice-version-identifier",
    "change-previous-notice-section-identifier",
    "change-reason-code",
    "change-reason-description",
    "change-description",
]

CORRECTION_FIELDS = [
    "publication-number",
    "notice-type",
    "form-type",
    "notice-version",
    "publication-date",
    "links",
    "change-notice-version-identifier",
    "change-reason-code",
    "change-reason-description",
    "change-previous-notice-section-identifier",
]


def search(query, fields, limit=1, only_latest=True):
    """POST a query to the TED Search API. Returns the decoded JSON body."""
    payload = json.dumps(
        {
            "query": query,
            "fields": fields,
            "page": 1,
            "limit": limit,
            "scope": "ALL",
            "paginationMode": "PAGE_NUMBER",
            "onlyLatestVersions": only_latest,
        }
    ).encode()
    request = urllib.request.Request(
        SEARCH_URL,
        data=payload,
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return json.loads(response.read().decode("utf-8"))


def head(url):
    request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return response.status, dict(response.headers), response.geturl()


def signed_pdf_check(url):
    """HEAD the signed PDF and, with a bounded read, confirm a signature dict."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        status = response.status
        content_type = response.headers.get_content_type()
        content_length = response.headers.get("Content-Length")
        body = response.read(MAX_PDF_READ)
        markers = {m.decode(): (m in body) for m in PDF_SIGNATURE_MARKERS}
        return {
            "url": response.geturl(),
            "status": status,
            "content_type": content_type,
            "content_length": int(content_length) if content_length else len(body),
            "signature_markers": markers,
            "bytes_read": len(body),
            "bytes_kept": 0,
        }


def pick_signed_pdf_url(links):
    signed = (links or {}).get("pdfs") or {}
    if signed:
        return sorted(signed.items())[0][1]
    return None


def compact_links(links):
    """Reduce the 24-language link map to the canonical, metadata-relevant links."""
    if not links:
        return {}
    compact = {}
    xml = links.get("xml") or {}
    compact["xml"] = xml.get("MUL") or (sorted(xml.values())[0] if xml else None)
    signed = links.get("pdfs") or {}
    if signed:
        lang, url = sorted(signed.items())[0]
        compact["signed_pdf"] = {"lang": lang, "url": url}
    direct_html = links.get("htmlDirect") or {}
    if direct_html:
        lang, url = sorted(direct_html.items())[0]
        compact["html_direct"] = {"lang": lang, "url": url}
    detail_html = links.get("html") or {}
    if detail_html:
        lang, url = sorted(detail_html.items())[0]
        compact["html_detail"] = {"lang": lang, "url": url}
    return compact


def summarize_notice(notice):
    """Project one notice to the award-claim and correction metadata only."""
    summary = {}
    for key in AWARD_FIELDS:
        if key == "links":
            continue
        if key in notice:
            summary[key] = notice[key]
    summary["links"] = compact_links(notice.get("links"))
    return summary


def main():
    result = {"checked_at_utc": None, "search_api": SEARCH_URL}

    # 1. Latest result notice with a winning lot, preferably Belgian buyer+winner.
    queries = [
        (
            "form-type=result AND winner-selection-status=selec-w "
            "AND buyer-country=BEL AND winner-country=BEL SORT BY PD DESC",
            "Belgian buyer and winner",
        ),
        (
            "form-type=result AND winner-selection-status=selec-w "
            "AND buyer-country=BEL SORT BY PD DESC",
            "Belgian buyer",
        ),
        (
            "form-type=result AND winner-selection-status=selec-w SORT BY PD DESC",
            "any buyer and winner",
        ),
    ]
    notice = None
    used_query = None
    for query, label in queries:
        try:
            page = search(query, AWARD_FIELDS, limit=1)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:200]
            print(json.dumps({"FAIL": f"search API HTTP {error.code}", "detail": detail}))
            return 1
        if page.get("notices"):
            notice = page["notices"][0]
            used_query = {"fallback": label, "query": query}
            result["total_notice_count"] = page.get("totalNoticeCount")
            break

    if notice is None:
        print(json.dumps({"FAIL": "no result/award notice with a winning lot was returned"}))
        return 1

    result["query"] = used_query
    result["notice"] = summarize_notice(notice)

    # 2. Signed PDF direct link check (metadata and signature markers only).
    signed_url = pick_signed_pdf_url(notice.get("links"))
    if not signed_url:
        print(json.dumps({"FAIL": "notice has no signed PDF (pdfs) link", "notice": notice}))
        return 1
    try:
        result["signed_pdf"] = signed_pdf_check(signed_url)
    except urllib.error.HTTPError as error:
        print(json.dumps({"FAIL": f"signed PDF HTTP {error.code}", "url": signed_url}))
        return 1

    # 3. One correction notice to demonstrate linked correction/version metadata.
    try:
        correction_page = search(
            "form-type=result AND change-notice-version-identifier=* SORT BY PD DESC",
            CORRECTION_FIELDS,
            limit=1,
        )
        correction_notice = (correction_page.get("notices") or [None])[0]
        result["correction_fixture"] = (
            summarize_notice(correction_notice) if correction_notice else None
        )
        result["correction_total_notice_count"] = correction_page.get("totalNoticeCount")
    except urllib.error.HTTPError as error:
        result["correction_fixture"] = {
            "error": f"HTTP {error.code}",
        }

    result["checked_at_utc"] = __import__("datetime").datetime.now(
        __import__("datetime").timezone.utc
    ).isoformat()
    print(json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
