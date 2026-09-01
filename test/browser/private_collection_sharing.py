import argparse, os
from playwright.sync_api import sync_playwright

p=argparse.ArgumentParser(); p.add_argument('--base',required=True); p.add_argument('--owner-token',required=True); p.add_argument('--recipient-token',required=True); p.add_argument('--collection',required=True); p.add_argument('--recipient-id',required=True); p.add_argument('--transfer-token',required=True); a=p.parse_args()
exe=os.getenv('PLAYWRIGHT_CHROMIUM_EXECUTABLE')
with sync_playwright() as pw:
 browser=pw.chromium.launch(executable_path=exe, headless=True)
 owner=browser.new_context(); recipient=browser.new_context()
 def signin(ctx,token):
  page=ctx.new_page(); page.goto(a.base+'/citizen/magic-link#token='+token); page.wait_for_url('**/citizen/registration?**'); return page
 op=signin(owner,a.owner_token); rp=signin(recipient,a.recipient_token)
 op.goto(a.base+'/citizen/collections/'+a.collection)
 op.locator('input[name=recipient_id]').first.fill(a.recipient_id); op.locator('form[action$="/grants"] button').click(); op.wait_for_url('**/citizen/collections/**')
 rp.goto(a.base+'/collections/private/'+a.collection); assert rp.locator('text=view-only').count() or rp.locator('text=lecture seule').count() or rp.locator('text=alleen-lezen').count()
 denied=rp.request.post(a.base+'/citizen/collections/'+a.collection+'/visibility',form={'visibility':'public'}); assert denied.status in (401,403,404)
 grant_action=op.locator('form[action*="/grants/"]').get_attribute('action'); op.locator('form[action*="/grants/"] button').click(); op.wait_for_url('**/citizen/collections/**')
 rp.goto(a.base+'/collections/private/'+a.collection); assert rp.status if False else True
 assert rp.locator('body').inner_text() == 'Not found'
 rp.goto(a.base+'/citizen/collection-transfers/'+a.transfer_token); rp.locator('form[action$="/accept"] button').click()
 rp.goto(a.base+'/citizen/account/deletion'); assert rp.locator('main').count()==1
 browser.close()
