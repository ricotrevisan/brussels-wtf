"""Discover one evidence-gated declaration through the public UI."""
import argparse
import os
import re
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import expect, sync_playwright

parser = argparse.ArgumentParser()
parser.add_argument("--base", required=True)
parser.add_argument("--person", required=True)
parser.add_argument("--fact", required=True)
parser.add_argument("--name", required=True)
parser.add_argument("--source-page", required=True)
args = parser.parse_args()

with sync_playwright() as pw:
    options = {"headless": True}
    if executable := os.environ.get("PLAYWRIGHT_CHROMIUM_EXECUTABLE"):
        options["executable_path"] = executable
    browser = pw.chromium.launch(**options)
    for width in (1280, 390):
        page = browser.new_page(viewport={"width": width, "height": 900})
        for locale, heading, role in (
            ("en", "Verified facts", "First alderman and civil registrar"),
            ("fr", "Faits vérifiés", "Premier Echevin et Officier de l'Etat Civil"),
            ("nl", "Geverifieerde feiten", "Eerste schepen en ambtenaar van de burgerlijke stand"),
        ):
            page.goto(f"{args.base}/mandates?lang={locale}&q={args.name}&communes_submitted=1&commune[]=ixelles")
            link = page.locator("#verified-mandates").locator("..").get_by_role("link", name=args.name, exact=True)
            expect(link).to_have_attribute("href", f"/people/{args.person}?lang={locale}#fact-{args.fact}")
            expect(link.locator("..").locator('a[rel="external"]')).to_have_attribute(
                "href", f"https://www.ixelles.be/site/fr/download/transparence/mandats-2024.pdf#page={args.source_page}"
            )
            link.click()
            expect(page).to_have_url(f"{args.base}/people/{args.person}?lang={locale}#fact-{args.fact}")
            expect(page.get_by_role("heading", name=heading, exact=True)).to_be_visible()
            fact = page.locator(f"#fact-{args.fact}")
            expect(fact.get_by_role("heading", name=role, exact=True)).to_be_visible()
            expect(fact).to_contain_text("2024-12-01")
            expect(fact).to_contain_text("2024-12-31")
            expect(fact.get_by_role("link")).to_have_attribute(
                "href", f"https://www.ixelles.be/site/fr/download/transparence/mandats-2024.pdf#page={args.source_page}"
            )
            assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
            text = page.locator("body").inner_text()
            for private in ("281.10", "85.07.23", "12 345", "Signature", "Numéro national", "corroborating_facts"):
                assert private not in text
            # A real profile control must restore the directory search and commune selection,
            # including after a language change on the detail page.
            next_locale = {"en": "fr", "fr": "nl", "nl": "en"}[locale]
            page.locator(f'a[hreflang="{next_locale}"]').click()
            back = page.locator("a[data-reader-back]")
            expect(back).to_have_attribute("href", re.compile(r"^/mandates\?"))
            back.click()
            returned = urlparse(page.url)
            query = parse_qs(returned.query)
            assert returned.path == "/mandates"
            assert query["q"] == [args.name]
            assert query["commune[]"] == ["ixelles"]
            assert query["lang"] == [next_locale]
            if directory := os.environ.get("MANDATE_SCREENSHOT_DIR"):
                Path(directory).mkdir(parents=True, exist_ok=True)
                page.screenshot(path=str(Path(directory) / f"mandate-{locale}-{width}.png"), full_page=True)
        page.close()
    browser.close()
