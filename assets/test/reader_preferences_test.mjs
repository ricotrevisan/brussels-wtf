import test from "node:test"
import assert from "node:assert/strict"
import {enhanceCommuneSelection} from "../js/reader_preferences.mjs"

function browserFixture(href, stored) {
  const listeners = {}, navigations = []
  const boxes = ["ixelles", "uccle", "forest", "city-of-brussels"].map(value => ({value, checked: true}))
  const form = {
    querySelectorAll: selector => selector === 'input[name="commune[]"]' ? boxes : [],
    addEventListener: (event, callback) => listeners[event] = callback
  }
  const document = {querySelector: () => form}
  const values = new Map(stored === undefined ? [] : [["brussels.wtf:communes", JSON.stringify(stored)]])
  const localStorage = {
    getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
    removeItem: key => values.delete(key)
  }
  const window = {location: {href, replace: value => navigations.push(value)}, localStorage}
  return {window, document, localStorage, boxes, listeners, values, navigations}
}

for (const path of ["/", "/coverage/coming-up", "/coverage/decisions", "/mandates"]) {
  test(`returning preferences re-request ${path} before preview selection`, () => {
    const f = browserFixture(`https://brussels.wtf${path}?lang=nl&q=budget#content`, ["forest", "ixelles"])
    enhanceCommuneSelection(f.window, f.document, f.localStorage)
    assert.equal(f.navigations.length, 1)
    const target = new URL(f.navigations[0])
    assert.equal(target.pathname, path)
    assert.equal(target.searchParams.get("lang"), "nl")
    assert.equal(target.searchParams.get("q"), "budget")
    assert.equal(target.hash, "#content")
    assert.deepEqual(target.searchParams.getAll("commune[]"), ["forest", "ixelles"])
    assert.equal(target.searchParams.get("communes_submitted"), "1")
  })
}

test("first visit leaves the server's all-communes baseline intact", () => {
  const f = browserFixture("https://brussels.wtf/?lang=en")
  enhanceCommuneSelection(f.window, f.document, f.localStorage)
  assert.deepEqual(f.navigations, [])
  assert.ok(f.boxes.every(box => box.checked))
})

for (const query of ["communes_submitted=1&commune[]=ixelles", "commune[]=ixelles", "commune=ixelles"]) {
  test(`explicit URL wins over remembered preferences: ${query}`, () => {
    const f = browserFixture(`https://brussels.wtf/?${query}`, ["forest"])
    enhanceCommuneSelection(f.window, f.document, f.localStorage)
    assert.deepEqual(f.navigations, [])
    assert.equal(f.values.get("brussels.wtf:communes"), '["ixelles"]')
  })
}

test("explicit empty selection is remembered and restored without a redirect loop", () => {
  const f = browserFixture("https://brussels.wtf/?communes_submitted=1", ["forest"])
  enhanceCommuneSelection(f.window, f.document, f.localStorage)
  assert.equal(f.values.get("brussels.wtf:communes"), '[]')
  assert.deepEqual(f.navigations, [])
  const next = browserFixture("https://brussels.wtf/coverage/decisions", [])
  enhanceCommuneSelection(next.window, next.document, next.localStorage)
  assert.equal(new URL(next.navigations[0]).searchParams.get("communes_submitted"), "1")
})

test("form submit persists multiple choices without hiding already capped entries", () => {
  const f = browserFixture("https://brussels.wtf/")
  enhanceCommuneSelection(f.window, f.document, f.localStorage)
  f.boxes.forEach(box => box.checked = ["ixelles", "forest"].includes(box.value))
  f.listeners.submit()
  assert.equal(f.values.get("brussels.wtf:communes"), '["ixelles","forest"]')
  assert.deepEqual(f.navigations, []) // native GET submission requests the new selection
})

test("invalid stored values are ignored, stale communes are removed", () => {
  for (const invalid of [{commune: "forest"}, ["unknown"], [42]]) {
    const f = browserFixture("https://brussels.wtf/", invalid)
    enhanceCommuneSelection(f.window, f.document, f.localStorage)
    assert.deepEqual(f.navigations, [])
  }
  const f = browserFixture("https://brussels.wtf/", ["forest", "unknown", "forest"])
  enhanceCommuneSelection(f.window, f.document, f.localStorage)
  assert.deepEqual(new URL(f.navigations[0]).searchParams.getAll("commune[]"), ["forest"])
})

test("malformed JSON cannot interrupt native form submission", () => {
  const f = browserFixture("https://brussels.wtf/")
  f.values.set("brussels.wtf:communes", "not-json")
  assert.doesNotThrow(() => enhanceCommuneSelection(f.window, f.document, f.localStorage))
  assert.deepEqual(f.navigations, [])
  assert.doesNotThrow(() => f.listeners.submit())
})

test("storage read, write, removal, and access failures leave native GET usable", () => {
  for (const href of ["https://brussels.wtf/", "https://brussels.wtf/?communes_submitted=1&commune[]=ixelles"]) {
    const f = browserFixture(href)
    const broken = {getItem() {throw Error("blocked")}, setItem() {throw Error("blocked")}, removeItem() {throw Error("blocked")}}
    assert.doesNotThrow(() => enhanceCommuneSelection(f.window, f.document, broken))
    assert.doesNotThrow(() => f.listeners.submit())
    Object.defineProperty(f.window, "localStorage", {get() {throw Error("blocked")}})
    assert.doesNotThrow(() => enhanceCommuneSelection(f.window, f.document))
  }
})
