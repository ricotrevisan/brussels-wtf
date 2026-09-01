import argparse, json, os
from pathlib import Path
from playwright.sync_api import sync_playwright

p=argparse.ArgumentParser(); p.add_argument("phase"); p.add_argument("--base",required=True); p.add_argument("--mail",required=True); p.add_argument("--state",required=True); p.add_argument("--payload",required=True); a=p.parse_args()
data=json.loads(Path(a.payload).read_text())
email="retention-browser@example.test"

def magic_sign_in(page, locale):
    labels={"fr":("Adresse e-mail","Envoyer le lien de connexion"),"nl":("E-mailadres","Aanmeldlink versturen"),"en":("Email address","Send sign-in link")}
    page.goto(f"{a.base}/citizen/sign-in?lang={locale}")
    field,button=labels[locale]; page.get_by_label(field).fill(email); page.get_by_role("button",name=button).click()
    page.wait_for_timeout(100)
    mail=json.loads(Path(a.mail).read_text()); assert mail["locale"]==locale
    page.goto(a.base+mail["token"]); page.wait_for_url(f"**/citizen/registration?lang={locale}")

with sync_playwright() as pw:
    opts={"headless":True}; exe=os.environ.get("PLAYWRIGHT_CHROMIUM_EXECUTABLE")
    if exe: opts["executable_path"]=exe
    browser=pw.chromium.launch(**opts)
    context=browser.new_context(storage_state=a.state if Path(a.state).exists() else None)
    page=context.new_page()
    if a.phase=="signin":
        magic_sign_in(page,"fr")
    elif a.phase in ("warn30","warn7"):
        locale=data["locale"]; expected=data["expected"]
        page.goto(f"{a.base}/feed?lang={locale}")
        warning=page.locator("[data-inactivity-warning]")
        assert warning.count()==1 and expected in warning.inner_text(), page.locator("body").inner_text()
        page.goto(f"{a.base}/citizen/account/deletion?lang={locale}")
        assert page.locator("html").get_attribute("lang")==locale
        assert page.locator("[data-collection-blocker]").count()==1
        assert data["resolution"] in page.locator("body").inner_text()
    elif a.phase=="select":
        page.goto(a.base+"/citizen/account/deletion?lang=en")
        page.get_by_role("button",name="Delete automatically",exact=True).click()
        page.wait_for_url("**/citizen/account/deletion")
        assert page.locator("[data-resolution-status]").inner_text()=="delete"
    elif a.phase=="resignin":
        magic_sign_in(page,"nl")
        page.goto(a.base+"/feed?lang=nl"); assert page.locator("[data-inactivity-warning]").count()==0
    elif a.phase=="deleted":
        page.goto(a.base+"/citizen/account/deletion?lang=en")
        assert page.locator("body").inner_text()==""
    context.storage_state(path=a.state); browser.close()
