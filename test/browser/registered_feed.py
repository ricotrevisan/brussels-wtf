import argparse,json,os
from pathlib import Path
from playwright.sync_api import sync_playwright
p=argparse.ArgumentParser();p.add_argument("--base",required=True);p.add_argument("--mail",required=True);a=p.parse_args()
def login(page):
 page.goto(a.base+json.loads(Path(a.mail).read_text())["token"]);page.wait_for_url("**/citizen/registration?lang=en")
with sync_playwright() as pw:
 opts={"headless":True};exe=os.environ.get("PLAYWRIGHT_CHROMIUM_EXECUTABLE")
 if exe: opts["executable_path"]=exe
 browser=pw.chromium.launch(**opts);page=browser.new_page();login(page);page.goto(a.base+"/feed?lang=en")
 links=page.locator("[data-registered-feed] a");assert links.count()==4
 expected={"/dossiers/clean-air?revision=rev-dossier","/people/00000000-0000-0000-0000-000000000001?fact=fact-person","/companies/0123456789?fact=fact-company","/meetings/ixelles/2026-09?revision=rev-commune"}
 assert {links.nth(i).get_attribute("href") for i in range(4)}==expected
 page.locator("[data-registered-feed] form").first.locator("button").click();page.context.clear_cookies()
 page.goto(a.base+"/citizen/sign-in?lang=en");page.get_by_label("Email").fill("joined@example.test");page.get_by_role("button",name="Send magic link").click();login(page);page.goto(a.base+"/feed?lang=en")
 assert page.locator('[data-registered-feed] li[data-read="true"]').count()==1
 page.goto(a.base+"/citizen/account?lang=en");assert "Public or unlisted collections must be transferred or deleted" in page.locator("body").inner_text()
 boxes=page.locator('input[type="checkbox"]');assert boxes.count()==2
 for i in range(boxes.count()): boxes.nth(i).check()
 page.get_by_role("button",name="Delete account").click();page.wait_for_url(a.base+"/")
 page.goto(a.base+"/feed?lang=en");assert page.locator("[data-registered-feed]").count()==0
 browser.close()
