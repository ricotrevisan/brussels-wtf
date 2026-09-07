import argparse, json, os
from pathlib import Path
from playwright.sync_api import sync_playwright

p=argparse.ArgumentParser(); p.add_argument("phase",choices=["follow","verify"]); p.add_argument("--base",required=True); p.add_argument("--mail",required=True); p.add_argument("--payload",required=True); a=p.parse_args()
data=json.loads(Path(a.payload).read_text())

def sign_in(page):
    page.goto(a.base+"/citizen/sign-in?lang=fr")
    page.get_by_label("Adresse e-mail").fill("registered-feed-browser@example.test")
    page.get_by_role("button",name="Envoyer le lien de connexion").click()
    page.wait_for_timeout(100)
    link=json.loads(Path(a.mail).read_text())["token"]
    page.goto(a.base+link)
    page.wait_for_url("**/citizen/registration?lang=fr")

with sync_playwright() as pw:
    opts={"headless":True}; exe=os.environ.get("PLAYWRIGHT_CHROMIUM_EXECUTABLE")
    if exe: opts["executable_path"]=exe
    browser=pw.chromium.launch(**opts)
    context=browser.new_context(); page=context.new_page(); sign_in(page)
    if a.phase=="follow":
        pages=[
          (f'/dossiers/{data["dossier"]}?lang=fr', "Suivre ce dossier"),
          (f'/people/{data["person"]}?lang=fr', "Suivre les mises à jour de ce profil"),
          (f'/companies/{data["company"]}?lang=fr', "Suivre les mises à jour de ce profil"),
        ]
        for path,label in pages:
            page.goto(a.base+path); page.get_by_role("button",name=label,exact=True).click(); page.wait_for_url("**/feed?lang=fr")
        page.goto(a.base+"/?lang=fr")
        page.locator("details.reader-filters > summary").click()
        page.locator(f'button[form="follow-commune-{data["commune"]}"]').click(); page.wait_for_url("**/feed?lang=fr")
    else:
        page.goto(a.base+"/feed?lang=fr")
        expected={
          "Correction factuelle — Dossier": data["dossier"],
          "Mandat public vérifié — Personne": data["person"],
          "Nouvelles décisions documentées — Commune": data["commune"],
        }
        links=page.locator("[data-registered-feed] a")
        assert links.count()==3, page.locator("body").inner_text()
        for label,href in expected.items():
            anchor=page.get_by_role("link",name=label,exact=True)
            assert anchor.count()==1 and anchor.get_attribute("href")==href, (label, anchor.get_attribute("href"), href)
        body=page.locator("body").inner_text()
        for excluded in ["Correction typographique", "récupération", "PRIVATE REVIEW", "UNVERIFIED", "Entité juridique"]:
            assert excluded not in body
        for label,href in expected.items():
            anchor=page.get_by_role("link",name=label,exact=True); anchor.click()
            page.wait_for_url("**"+href)
            page.goto(a.base+"/feed?lang=fr")
            item=page.get_by_role("link",name=label,exact=True).locator("xpath=..")
            item.get_by_role("button",name="Marquer comme lu",exact=True).click()
            page.wait_for_url("**/feed?lang=fr")
        assert page.locator('[data-registered-feed] li[data-read="true"]').count()==3
        context.close()
        context=browser.new_context(); page=context.new_page(); sign_in(page)
        page.goto(a.base+"/feed?lang=fr")
        assert page.locator('[data-registered-feed] li[data-read="true"]').count()==3
        assert page.locator('[data-registered-feed] li').count()==3
    browser.close()
