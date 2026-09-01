import argparse,json,os
from pathlib import Path
from playwright.sync_api import sync_playwright
p=argparse.ArgumentParser(); p.add_argument("--base",required=True); p.add_argument("--mail",required=True); p.add_argument("--expired",required=True); p.add_argument("--secret",required=True); a=p.parse_args()
with sync_playwright() as pw:
  opts={"headless":True}; exe=os.environ.get("PLAYWRIGHT_CHROMIUM_EXECUTABLE")
  if exe: opts["executable_path"]=exe
  browser=pw.chromium.launch(**opts); page=browser.new_page()
  page.add_init_script("localStorage.setItem('brussels.wtf:personal-feed:v1', JSON.stringify({follows:[{type:'commune',id:'ixelles',label:'Ixelles'},{type:'dossier',id:'not-selected',label:'Do not import'}],notifications:[]}))")
  page.goto(a.base+"/citizen/sign-in?lang=en")
  before={c["name"]:c["value"] for c in page.context.cookies()}.get("_brussels_wtf_key")
  page.get_by_label("Email").fill("browser@example.test"); page.get_by_role("button",name="Send magic link").click()
  assert "If the address is valid" in page.locator("body").inner_text(); assert "browser@example.test" not in page.content()
  mail=json.loads(Path(a.mail).read_text()); link=mail["token"]; token=link.split("#token=",1)[1]
  seen=[]; page.on("request", lambda request: seen.append(request.url))
  page.goto(a.base+link); page.wait_for_url("**/citizen/registration?lang=en")
  assert all(token not in url for url in seen); assert token not in page.url
  cookies={c["name"]:c for c in page.context.cookies()}; c=cookies["_brussels_wtf_key"]
  assert c["secure"] and c["httpOnly"] and c["sameSite"]=="Lax"
  assert "citizen_session" not in cookies
  assert cookies["_brussels_wtf_key"]["value"] != before
  text=page.locator("body").inner_text(); assert "Import selected local follows" in text and "Separately claim an anonymous collection" in text
  boxes=page.locator('#local-follow-targets input[type=checkbox]'); assert boxes.count()==2; boxes.nth(0).check(); page.get_by_role("button",name="Import selected local follows").click(); result=page.get_by_test_id("citizen-choice-result"); assert result.get_attribute("data-result")=="imported" and result.get_attribute("data-count")=="1"
  page.goto(a.base+"/citizen/registration"); page.get_by_label("Management secret").fill(a.secret); page.get_by_role("button",name="Separately claim an anonymous collection").click(); result=page.get_by_test_id("citizen-choice-result"); assert result.get_attribute("data-result")=="claimed"
  page.goto(a.base+link); page.wait_for_timeout(500); assert page.locator("body").inner_text().find("invalid or expired") >= 0
  page.context.clear_cookies(); expired=Path(a.expired).read_text().strip(); page.goto(a.base+expired); page.wait_for_timeout(500); assert "invalid or expired" in page.locator("body").inner_text(); page.goto(a.base+"/citizen/registration"); assert "invalid or expired" in page.locator("body").inner_text()
  denied=page.goto(a.base+"/review"); assert "/review/login" in page.url
  browser.close()
