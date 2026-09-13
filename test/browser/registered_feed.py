import argparse, json, os
from pathlib import Path
from playwright.sync_api import sync_playwright, expect

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
          "Fonction de gestion vérifiée — Entité juridique": data["company"],
          "Nouvelles décisions documentées — Commune": data["commune"],
        }
        links=page.locator("[data-registered-feed] a")
        assert links.count()==4, page.locator("body").inner_text()
        for label,href in expected.items():
            anchor=page.get_by_role("link",name=label,exact=True)
            assert anchor.count()==1 and anchor.get_attribute("href")==href, (label, anchor.get_attribute("href"), href)
        body=page.locator("body").inner_text()
        for excluded in ["Correction typographique", "récupération", "PRIVATE REVIEW", "UNVERIFIED", "PRIVATE HOME ADDRESS", "PRIVATE FAMILY", "PRIVATE-CBE-RELEASE-KEY"]:
            assert excluded not in body
        for label,href in expected.items():
            anchor=page.get_by_role("link",name=label,exact=True); anchor.click()
            page.wait_for_url("**"+href)
            target=page.locator('[id="'+href.split("#",1)[1]+'"]')
            assert target.count()==1, (href, page.locator("body").inner_text())
            expect(target).to_be_visible()
            if href==data["company"]:
                assert "Alex Public" in target.inner_text()
                assert target.locator('a[href^="https://www.ejustice.just.fgov.be/"]').count()>0
            page.goto(a.base+"/feed?lang=fr")
            item=page.get_by_role("link",name=label,exact=True).locator("xpath=..")
            item.get_by_role("button",name="Marquer comme lu",exact=True).click()
            page.wait_for_url("**/feed?lang=fr")
        assert page.locator('[data-registered-feed] li[data-read="true"]').count()==4
        context.close()
        context=browser.new_context(); page=context.new_page(); sign_in(page)
        page.goto(a.base+"/feed?lang=fr")
        assert page.locator('[data-registered-feed] li[data-read="true"]').count()==4
        assert page.locator('[data-registered-feed] li').count()==4
    browser.close()
