import argparse, json, os
from pathlib import Path
from playwright.sync_api import sync_playwright, expect

p=argparse.ArgumentParser(); p.add_argument("phase",choices=["follow","verify","unfollow"]); p.add_argument("--base",required=True); p.add_argument("--mail",required=True); p.add_argument("--payload",required=True); a=p.parse_args()
data=json.loads(Path(a.payload).read_text())

def sign_in(page, email="registered-feed-browser@example.test"):
    page.goto(a.base+"/citizen/sign-in?lang=fr")
    page.get_by_label("Adresse e-mail").fill(email)
    page.get_by_role("button",name="Envoyer le lien de connexion").click()
    page.wait_for_timeout(100)
    link=json.loads(Path(a.mail).read_text())["token"]
    page.goto(a.base+link)
    page.wait_for_url("**/citizen/registration?lang=fr")

def post_in_browser(page, path, token):
    return page.evaluate("""async ({path,token}) => {
        const response = await fetch(path, {method:'POST', headers:{'content-type':'application/x-www-form-urlencoded'}, body:new URLSearchParams({_csrf_token:token})});
        return response.status;
    }""", {"path":path,"token":token})

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
        page.goto(a.base+"/coverage/coming-up?lang=fr")
        page.locator("details.reader-filters > summary").click()
        page.locator(f'button[form="follow-commune-{data["commune"]}"]').click(); page.wait_for_url("**/feed?lang=fr")
    elif a.phase=="unfollow":
        paths=[f'/dossiers/{data["dossier"]}', f'/people/{data["person"]}', f'/companies/{data["company"]}', '/coverage/coming-up']
        for locale,label in [("fr","Ne plus suivre"),("nl","Niet meer volgen"),("en","Unfollow")]:
            for path in paths:
                page.goto(a.base+path+"?lang="+locale)
                if path=="/coverage/coming-up": page.locator("details.reader-filters > summary").click()
                expect(page.get_by_role("button", name=label, exact=True)).to_be_visible()
                assert page.locator("[data-followed-state]").count()==1
                if locale=="en" and path==paths[0]:
                    for width in [390,1280]:
                        page.set_viewport_size({"width":width,"height":900})
                        assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
                        page.screenshot(path=f"/tmp/issue54-unfollow-{width}.png",full_page=True)
            page.goto(a.base+"/feed?lang="+locale)
            assert page.locator("[data-registered-follows] li").count()==4
            assert page.get_by_role("button",name=label,exact=True).count()==4
        # Missing CSRF cannot remove a follow, even in an authenticated browser.
        action=page.locator('[data-registered-follows] form').first.get_attribute('action')
        response=context.request.post(a.base+action)
        assert response.status==403
        assert context.request.get(a.base+action).status==404
        stranger=browser.new_context(); stranger_page=stranger.new_page()
        assert stranger.request.post(a.base+action).status==403
        sign_in(stranger_page, "other-unfollow-browser@example.test")
        stranger_page.goto(a.base+"/feed?lang=en")
        assert stranger_page.locator('[data-registered-follows] li').count()==0
        assert stranger_page.locator('[data-registered-feed] li').count()==0
        stranger_page.goto(a.base+paths[0]+"?lang=en")
        assert stranger_page.locator('[data-followed-state]').count()==0
        token=stranger_page.locator('input[name="_csrf_token"]').first.input_value()
        assert post_in_browser(stranger_page, action, token)==200
        stranger.close()
        page.reload()
        assert page.locator('[data-registered-follows] li').count()==4
        for index,path in enumerate(paths):
            page.set_viewport_size({"width":390 if index%2 else 1280,"height":900})
            page.goto(a.base+path+"?lang=en")
            if path=="/coverage/coming-up":
                # Exercise removal from the registered feed for the final target.
                page.goto(a.base+"/feed?lang=en")
            button=page.get_by_role("button",name="Unfollow",exact=True)
            form=button.locator('xpath=..')
            removal_action=form.get_attribute('action')
            removal_token=form.locator('input[name="_csrf_token"]').input_value()
            button.click()
            page.wait_for_url("**/feed?lang=en")
            assert post_in_browser(page, removal_action, removal_token)==200
            assert page.locator("[data-registered-follows] li").count()==3-index
            assert page.locator('[data-registered-feed] li[data-read="true"]').count()==4
            page.goto(a.base+path+"?lang=en")
            assert page.locator('[data-unfollow-control="true"]').count()==0
        page.goto(a.base+"/feed?lang=en")
        assert "12-month expiry" in page.locator('body').inner_text()
        # Following again preserves previously received history; the commune's
        # own control also removes its durable follow.
        page.goto(a.base+"/coverage/coming-up?lang=en")
        page.locator("details.reader-filters > summary").click()
        page.locator(f'button[form="follow-commune-{data["commune"]}"]').click()
        page.wait_for_url("**/feed?lang=en")
        assert page.locator('[data-registered-feed] li[data-read="true"]').count()==4
        page.goto(a.base+"/coverage/coming-up?lang=en")
        page.locator("details.reader-filters > summary").click()
        page.get_by_role("button",name="Unfollow",exact=True).click()
        page.wait_for_url("**/feed?lang=en")
        assert page.locator('[data-registered-follows] li').count()==0
        assert page.locator('[data-registered-feed] li[data-read="true"]').count()==4
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
