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

for (const path of ['/', '/coverage/coming-up', '/coverage/awaiting-outcome', '/coverage/decisions', '/mandates']) {
  for (const suffix of path === '/' ? [''] : ['', '/']) {
    test(`return context restores filtered results from ${path}${suffix}`, () => {
      const query = '?q=budget&commune%5B%5D=ixelles&commune%5B%5D=forest&communes_submitted=1&lang=en'
      let saved
      const storage = {setItem: (_, value) => {saved = value}, getItem: () => saved}
      const back = [{href: '/?lang=nl'}]
      const document = {documentElement: {lang: 'nl'}, querySelectorAll: s => s === 'a[hreflang]' ? [] : back}

      enhanceReaderNavigation({location: {href: `https://publication.test${path}${suffix}${query}`}}, document, storage)
      assert.equal(saved, path + query)
      enhanceReaderNavigation({location: {href: 'https://publication.test/meetings/ixelles/267#item-4'}}, document, storage)
      const result = new URL(back[0].href, 'https://publication.test')
      assert.equal(result.pathname, path)
      assert.equal(result.searchParams.get('q'), 'budget')
      assert.deepEqual(result.searchParams.getAll('commune[]'), ['ixelles', 'forest'])
      assert.equal(result.searchParams.get('communes_submitted'), '1')
      assert.equal(result.searchParams.get('lang'), 'nl')
      assert.equal(result.hash, '')
    })
  }
}

test('saved trailing-slash result destinations remain usable', () => {
  for (const path of ['/coverage/coming-up', '/coverage/awaiting-outcome', '/coverage/decisions', '/mandates']) {
    const back = [{href: '/?lang=en'}]
    const document = {documentElement: {lang: 'en'}, querySelectorAll: s => s === 'a[hreflang]' ? [] : back}
    enhanceReaderNavigation({location: {href: 'https://publication.test/people/person'}}, document, {getItem: () => `${path}/?q=budget&communes_submitted=1`})
    assert.equal(back[0].href, `${path}?q=budget&communes_submitted=1&lang=en`)
  }
})

test('detail pages do not overwrite the saved results destination', () => {
  const storage = {setItem: () => assert.fail('detail page saved as results'), getItem: () => null}
  enhanceReaderNavigation({location: {href: 'https://publication.test/people/person'}}, {querySelectorAll: () => []}, storage)
})

test('untrusted return destinations and unavailable browser storage do not break reading', () => {
  for (const saved of ['https://other.test/', '//other.test/', 'https://other.test/mandates', '/review', '/citizen/account', '/coverage', '/coverage/not-a-category', '/coverage/coming-up/extra', '/mandates/person']) {
    const back = [{href:'/?lang=en'}]
    const document = {documentElement:{lang:'en'}, querySelectorAll:s => s === 'a[hreflang]' ? [] : back}
    enhanceReaderNavigation({location:{href:'https://publication.test/meetings/ixelles/267'}}, document, {getItem:()=>saved})
    assert.equal(back[0].href,'/?lang=en')
  }
  const links = [{href:'https://publication.test/meetings/ixelles/267?lang=nl'}]
  enhanceReaderNavigation({location:{href:'https://publication.test/meetings/ixelles/267#item'}}, {querySelectorAll:()=>links}, {getItem:()=>{throw new Error('blocked')}})
  assert.equal(new URL(links[0].href).hash,'#item')
})
