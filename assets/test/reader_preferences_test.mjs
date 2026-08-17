import test from "node:test"
import assert from "node:assert/strict"
import {enhanceCommuneSelection} from "../js/reader_preferences.mjs"

function browserFixture(href, stored) {
  const listeners = {}
  const boxes = ["ixelles", "forest"].map(value => ({value, checked: true}))
  const entries = ["ixelles", "forest"].map(commune => ({dataset: {commune}, hidden: false}))
  const form = {
    querySelectorAll: selector => selector === 'input[name="commune[]"]' ? boxes : [],
    addEventListener: (event, callback) => listeners[event] = callback
  }
  const document = {
    querySelector: selector => selector === "[data-reader-communes]" ? form : null,
    querySelectorAll: selector => selector === "[data-commune]" ? entries : []
  }
  const values = new Map(stored ? [["brussels.wtf:communes", JSON.stringify(stored)]] : [])
  const localStorage = {
    getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
    removeItem: key => values.delete(key)
  }

  return {window: {location: {href}}, document, localStorage, boxes, entries, listeners, values}
}

test("a returning reader's local commune choice changes visible entries", () => {
  const fixture = browserFixture("https://brussels.wtf/?lang=en", ["forest"])
  enhanceCommuneSelection(fixture.window, fixture.document, fixture.localStorage)

  assert.deepEqual(fixture.boxes.map(box => [box.value, box.checked]), [["ixelles", false], ["forest", true]])
  assert.deepEqual(fixture.entries.map(entry => [entry.dataset.commune, entry.hidden]), [["ixelles", true], ["forest", false]])
})

test("a server-rendered selection is remembered for the next visit", () => {
  const fixture = browserFixture(
    "https://brussels.wtf/?lang=en&communes_submitted=1&commune%5B%5D=ixelles",
    null
  )
  enhanceCommuneSelection(fixture.window, fixture.document, fixture.localStorage)

  assert.equal(fixture.values.get("brussels.wtf:communes"), '["ixelles"]')
  assert.equal(fixture.entries.every(entry => entry.hidden === false), true)
})
