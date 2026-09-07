import test from 'node:test'
import assert from 'node:assert/strict'
import {enhanceReaderNavigation} from '../js/reader_navigation.mjs'

test('language changes preserve exact item anchors and filtered return context', () => {
  const links = [{href:'https://publication.test/meetings/ixelles/267?lang=nl'}]
  const back = [{href:'https://publication.test/?lang=en'}]
  const document = {documentElement:{lang:'nl'}, querySelectorAll: s => s === 'a[hreflang]' ? links : back}
  const storage = {getItem: () => '/?q=budget&commune%5B%5D=ixelles&communes_submitted=1'}
  enhanceReaderNavigation({location:{href:'https://publication.test/meetings/ixelles/267?lang=en#agenda-item-4'}}, document, storage)
  assert.equal(new URL(links[0].href).hash, '#agenda-item-4')
  const result = new URL(back[0].href, 'https://publication.test')
  assert.equal(result.searchParams.get('q'), 'budget')
  assert.deepEqual(result.searchParams.getAll('commune[]'), ['ixelles'])
  assert.equal(result.searchParams.get('lang'), 'nl')
})

test('untrusted return destinations and unavailable browser storage do not break reading', () => {
  for (const saved of ['https://other.test/', '//other.test/', '/review', '/citizen/account']) {
    const back = [{href:'/?lang=en'}]
    const document = {documentElement:{lang:'en'}, querySelectorAll:s => s === 'a[hreflang]' ? [] : back}
    enhanceReaderNavigation({location:{href:'https://publication.test/meetings/ixelles/267'}}, document, {getItem:()=>saved})
    assert.equal(back[0].href,'/?lang=en')
  }
  const links = [{href:'https://publication.test/meetings/ixelles/267?lang=nl'}]
  enhanceReaderNavigation({location:{href:'https://publication.test/meetings/ixelles/267#item'}}, {querySelectorAll:()=>links}, {getItem:()=>{throw new Error('blocked')}})
  assert.equal(new URL(links[0].href).hash,'#item')
})
