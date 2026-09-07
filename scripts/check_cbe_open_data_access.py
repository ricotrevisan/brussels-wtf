#!/usr/bin/env python3
"""Credential-free preflight for official CBE Open Data registration materials.

This deliberately does not log in, accept terms, or download licensed data.
"""
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ENDPOINTS = {
    "product page": ("https://economie.fgov.be/fr/themes/entreprises/banque-carrefour-des/services-pour-tous/reutilisation-de-donnees/banque-carrefour-des-0", "text/html"),
    "licence": ("https://economie.fgov.be/sites/default/files/Files/Entreprises/BCE/Licence-BCE-Open-Data-Conditions-d-utilisation.pdf", "application/pdf"),
    "catalogue": ("https://economie.fgov.be/sites/default/files/Files/Entreprises/BCE/Catalogue-des-donnees-reutilisables-BCE-opendata.pdf", "application/pdf"),
    "cookbook": ("https://economie.fgov.be/sites/default/files/Files/Entreprises/BCE/Cookbook-BCE-Open-Data.pdf", "application/pdf"),
    "registration portal": ("https://kbopub.economie.fgov.be/kbo-open-data/login?lang=fr", "text/html"),
}

def main() -> int:
    failed = False
    for name, (url, expected) in ENDPOINTS.items():
        try:
            request = Request(url, headers={"User-Agent": "brussels-wtf-cbe-access-preflight/1.0"})
            with urlopen(request, timeout=20) as response:
                content_type = response.headers.get_content_type()
                ok = response.status == 200 and content_type == expected
                print(f"{'OK' if ok else 'FAIL'} {name}: HTTP {response.status} {content_type} ({response.url})")
                failed |= not ok
        except (HTTPError, URLError, TimeoutError) as error:
            print(f"FAIL {name}: {error}")
            failed = True
    print("BLOCKED: authenticated product download requires operator registration and licence acceptance.")
    return 1 if failed else 0

if __name__ == "__main__":
    raise SystemExit(main())
