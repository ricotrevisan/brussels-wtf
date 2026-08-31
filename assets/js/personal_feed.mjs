const KEY = "brussels.wtf:personal-feed:v1"
const TYPES = new Set(["dossier", "person", "legal_entity", "commune"])
const COMMUNES = new Set(["ixelles", "uccle", "forest", "city-of-brussels"])
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const SLUG = /^[a-z0-9]+(?:-[a-z0-9]+)*$/
const ENTERPRISE = /^\d{10}$/
const ELIGIBLE_EVENTS = new Set(["published", "factual_correction", "republished", "verified_fact"])

export function validTarget(target) {
  if (!target || !TYPES.has(target.type) || typeof target.id !== "string") return false
  if (target.type === "person") return UUID.test(target.id)
  if (target.type === "legal_entity") return ENTERPRISE.test(target.id)
  if (target.type === "commune") return COMMUNES.has(target.id)
  return SLUG.test(target.id)
}
function empty() { return {follows: [], notifications: []} }
export function load(storage) {
  try {
    const value = JSON.parse(storage.getItem(KEY))
    if (!value || !Array.isArray(value.follows) || !Array.isArray(value.notifications)) return empty()
    return {follows: value.follows.filter(validTarget), notifications: value.notifications.filter(validNotification)}
  } catch (_) { return empty() }
}
function validNotification(n) {
  return n && typeof n.id === "string" && validTarget(n.target) && ELIGIBLE_EVENTS.has(n.eventType) &&
    typeof n.url === "string" && n.url.startsWith("/") && !n.url.startsWith("//") &&
    typeof n.title === "string" && typeof n.occurredAt === "string" && !Number.isNaN(Date.parse(n.occurredAt))
}
function save(storage, value) { storage.setItem(KEY, JSON.stringify(value)); return value }
export function importSnapshot(storage, targets) {
  const state = load(storage), additions = targets.filter(validTarget)
  const byKey = new Map([...state.follows, ...additions].map(t => [`${t.type}:${t.id}`, {type:t.type,id:t.id}]))
  return save(storage, {...state, follows: [...byKey.values()]})
}
export function ingestUpdates(storage, updates) {
  const state = load(storage), followed = new Set(state.follows.map(t => `${t.type}:${t.id}`))
  const byId = new Map(state.notifications.map(n => [n.id, n]))
  updates.filter(validNotification).filter(n => followed.has(`${n.target.type}:${n.target.id}`)).forEach(n => {
    if (!byId.has(n.id)) byId.set(n.id, {...n, readAt: null})
  })
  return save(storage, {...state, notifications:[...byId.values()]})
}
export function markRead(storage, id, now = new Date()) {
  const state=load(storage)
  return save(storage, {...state, notifications:state.notifications.map(n => n.id === id ? {...n,readAt:now.toISOString()} : n)})
}
export function cleanup(storage, now = new Date()) {
  const state=load(storage), cutoff=new Date(now); cutoff.setUTCMonth(cutoff.getUTCMonth()-12)
  return save(storage, {...state, notifications:state.notifications.filter(n => new Date(n.occurredAt) >= cutoff)})
}
export function enhancePersonalFeed(window, document, storage) {
  const importForm=document.querySelector("[data-follow-import]")
  if (importForm) importForm.addEventListener("submit", e => {
    e.preventDefault(); const selected=[...importForm.querySelectorAll("input[data-follow-target]:checked")]
      .map(i => ({type:i.dataset.type,id:i.dataset.identifier}))
    importSnapshot(storage, selected); window.location.assign("/feed")
  })
  const feed=document.querySelector("[data-personal-feed]"); if (!feed) return
  const state=cleanup(storage, new Date())
  for (const n of state.notifications.sort((a,b) => b.occurredAt.localeCompare(a.occurredAt))) {
    const li=document.createElement("li"), a=document.createElement("a")
    a.textContent=n.title; a.href=n.url; if (!n.readAt) li.dataset.unread="true"
    a.addEventListener("click", () => markRead(storage,n.id,new Date()))
    li.appendChild(a); feed.appendChild(li)
  }
}
