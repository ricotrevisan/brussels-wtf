import argparse, json, os
from playwright.sync_api import sync_playwright

p=argparse.ArgumentParser()
for name in ('base','owner-token','recipient-token','private','accept','decline','cancel','delete','recipient-id'): p.add_argument('--'+name, required=True)
a=p.parse_args(); exe=os.getenv('PLAYWRIGHT_CHROMIUM_EXECUTABLE'); evidence=[]
with sync_playwright() as pw:
 browser=pw.chromium.launch(executable_path=exe, headless=True)
 owner=browser.new_context(); recipient=browser.new_context()
 def signin(ctx, token):
  page=ctx.new_page(); page.goto(a.base+'/citizen/magic-link#token='+token); page.wait_for_url('**/citizen/registration?**'); return page
 op=signin(owner,a.owner_token); rp=signin(recipient,a.recipient_token)
 # Localized owner copy in every public locale.
 for lang, phrase in [('en','People with view access'),('fr','Personnes ayant accès en lecture'),('nl','Personen met leestoegang')]:
  op.goto(f'{a.base}/citizen/collections/{a.private}?lang={lang}'); actual=op.locator('body').inner_text(); assert phrase in actual, (lang, actual)
 # Grant through the owner form, see recipient label and revoke control.
 op.locator('input[name=recipient_id]').first.fill(a.recipient_id); op.locator('form[action$="/grants"] button').click()
 assert a.recipient_id in op.locator('main').inner_text(); assert op.locator('form[action*="/grants/"] button').count()==1
 rp.goto(a.base+'/collections/private/'+a.private+'?lang=en'); text=rp.locator('main').inner_text(); assert 'view-only' in text
 for forbidden in ('visibility','member','grant','transfer','delete','revoke','edit'): assert forbidden not in text.lower()
 # Cross-citizen mutation probes remain concealed and do not leak owner/recipient data.
 for method,url,data in [
  ('post',f'/citizen/collections/{a.private}/visibility',{'visibility':'public'}),
  ('post',f'/citizen/collections/{a.private}/members',{'target_type':'commune','target_identifier':'forest'}),
  ('delete',f'/citizen/collections/{a.private}',{})]:
  response=getattr(recipient.request,method)(a.base+url, form=data)
  body=response.text(); assert response.status in (401,403,404); assert 'browser-owner@' not in body and a.recipient_id not in body
  evidence.append({'method':method,'path':url,'status':response.status,'body':body})
 op.goto(a.base+'/citizen/collections/'+a.private); op.locator('form[action*="/grants/"] button').click()
 response=rp.goto(a.base+'/collections/private/'+a.private); assert response.status==404 and rp.locator('body').inner_text()=='Not found'
 def offer(collection):
  op.goto(a.base+'/citizen/collections/'+collection)
  op.locator('form[action$="/transfer-offers"] input[name=recipient_id]').fill(a.recipient_id)
  with op.expect_response(lambda r: r.request.method=='POST' and r.url.endswith('/transfer-offers')) as info: op.locator('form[action$="/transfer-offers"] button').click()
  location=info.value.headers['location']; return location
 # Recipient sees localized offers and explicitly declines one.
 decline_url=offer(a.decline)
 for lang, phrase in [('en','Ownership transfer'),('fr','Transfert de propriété'),('nl','Eigendomsoverdracht')]:
  rp.goto(a.base+decline_url+'?lang='+lang); assert phrase in rp.locator('main').inner_text()
 rp.goto(a.base+decline_url+'?lang=nl'); rp.locator('form[action$="/reject"] button').click()
 # Owner cancels another offer from the visible owner UI.
 cancel_url=offer(a.cancel); op.goto(a.base+'/citizen/collections/'+a.cancel+'?lang=fr'); assert 'Annuler l’offre' in op.locator('main').inner_text(); op.get_by_role('button', name='Annuler l’offre').click()
 evidence.append({'cancelled_offer': cancel_url})
 # Acceptance changes ownership atomically; old owner loses management immediately.
 accept_url=offer(a.accept); rp.goto(a.base+accept_url+'?lang=fr'); rp.locator('form[action$="/accept"] button').click()
 assert rp.url.endswith('/citizen/collections/'+a.accept); response=op.goto(a.base+'/citizen/collections/'+a.accept); assert response.status==404
 # Self-service deletion explicitly selects every remaining non-private collection.
 op.goto(a.base+'/citizen/account?lang=en'); assert 'Public or unlisted collections must be transferred or deleted.' in op.locator('main').inner_text()
 boxes=op.locator('input[type=checkbox]'); assert boxes.count()>=3
 for i in range(boxes.count()): boxes.nth(i).check()
 with op.expect_navigation(): op.locator('form[action="/citizen/account"] button').click()
 assert op.url.rstrip('/')==a.base
 assert op.goto(a.base+'/citizen/account').status==401
 evidence.append({'old_session':401})
 print(json.dumps(evidence))
 browser.close()
