import argparse, json, os
from pathlib import Path
from playwright.sync_api import sync_playwright

p=argparse.ArgumentParser(); p.add_argument("phase",choices=["import","verify"]); p.add_argument("--base",required=True); p.add_argument("--collection"); p.add_argument("--profile",required=True); a=p.parse_args()
with sync_playwright() as pw:
    executable=os.environ.get("PLAYWRIGHT_CHROMIUM_EXECUTABLE")
    opts={"headless":True};
    if executable: opts["executable_path"]=executable
    browser=pw.chromium.launch_persistent_context(a.profile,**opts)
    page=browser.pages[0]
    if a.phase=="import":
        page.goto(a.base+a.collection+"?lang=nl")
        boxes=page.locator("[data-follow-target]"); assert boxes.count() >= 2
        commune=page.locator('[data-follow-target][data-type="commune"]')
        expected=commune.get_attribute("data-identifier")
        for i in range(boxes.count()):
            if boxes.nth(i).get_attribute("data-type") != "commune": boxes.nth(i).uncheck()
        page.get_by_role("button",name="Selectie in mijn persoonlijke feed importeren").click()
        page.wait_for_url("**/feed?lang=nl")
        follows=page.evaluate("JSON.parse(localStorage.getItem('brussels.wtf:personal-feed:v1')).follows")
        assert len(follows)==1 and follows[0]["id"]==expected
        Path(a.profile,"expected.json").write_text(json.dumps(follows))
    else:
        expected=json.loads(Path(a.profile,"expected.json").read_text())
        page.goto(a.base+"/feed?lang=nl")
        anchor=page.get_by_role("link",name="Ixelles council publication",exact=True)
        anchor.wait_for()
        assert anchor.get_attribute("href").startswith("/meetings/ixelles/268?lang=nl#revision-")
        assert page.evaluate("JSON.parse(localStorage.getItem('brussels.wtf:personal-feed:v1')).follows")==expected
        anchor.click()
        page.wait_for_url("**/meetings/ixelles/268?lang=nl#revision-*")
        state=page.evaluate("JSON.parse(localStorage.getItem('brussels.wtf:personal-feed:v1'))")
        assert state["notifications"][0]["readAt"] is not None
    browser.close()
