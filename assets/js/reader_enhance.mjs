// Optional behaviour on top of server-rendered pages: everything here works without it.
export function enhanceFilters(window, document, onBusy) {
  const key = "brussels.wtf:filter-return"
  document.querySelectorAll("form[data-auto-submit]").forEach(form => {
    try {
      const saved = JSON.parse(window.sessionStorage.getItem(key))
      window.sessionStorage.removeItem(key)
      if (saved && saved.path === window.location.pathname) {
        window.scrollTo({top: saved.y, behavior: "instant"})
        form.querySelector(`input[value="${CSS.escape(saved.value)}"]`)?.focus({preventScroll: true})
      }
    } catch (_) { /* The filter works without restored position. */ }
    form.addEventListener("change", event => {
      if (event.target.matches?.('input[type="checkbox"]')) {
        try {
          window.sessionStorage.setItem(key, JSON.stringify({path: window.location.pathname, y: window.scrollY, value: event.target.value}))
        } catch (_) { /* Storage may be disabled. */ }
        onBusy?.()
        document.querySelector("main")?.setAttribute("aria-busy", "true")
        form.requestSubmit()
      }
    })
  })
}

export function enhanceAgenda(window, document) {
  const items = [...document.querySelectorAll("[data-agenda-item]")]
  if (!items.length) return

  const openFromHash = () => {
    const id = decodeURIComponent(window.location.hash.slice(1))
    const target = id && document.getElementById(id)
    if (!target || !target.matches("[data-agenda-item]")) return
    target.querySelector("details").open = true
    target.classList.remove("is-target")
    void target.offsetWidth
    target.classList.add("is-target")
    target.scrollIntoView({block: "start"})
  }
  openFromHash()
  window.addEventListener("hashchange", openFromHash)

  document.querySelector("[data-agenda-tools]")?.classList.replace("hidden", "flex")

  const toggle = document.querySelector("[data-expand-all]")
  toggle?.addEventListener("click", () => {
    const open = toggle.getAttribute("aria-pressed") !== "true"
    items.forEach(item => { if (!item.hidden) item.querySelector("details").open = open })
    toggle.setAttribute("aria-pressed", String(open))
    toggle.textContent = open ? toggle.dataset.collapseLabel : toggle.dataset.expandLabel
  })

  const tiles = [...document.querySelectorAll("[data-state-filter]")]
  const applyState = wanted => {
    items.forEach(item => {
      item.hidden =
        wanted === "contested" ? item.dataset.contested !== "true" :
        wanted === "all" ? false : item.dataset.state !== wanted
    })
    tiles.forEach(tile => tile.setAttribute("aria-pressed", String(tile.dataset.stateFilter === wanted)))
    report(wanted === "all")
  }
  const countEl = document.querySelector("[data-agenda-count]")
  const resultEl = document.querySelector("[data-agenda-result]")
  const report = idle => {
    const shown = items.filter(item => !item.hidden).length
    resultEl?.classList.toggle("hidden", idle)
    if (countEl) {
      countEl.textContent = idle ? "" : countEl.dataset.of
        .replace("%{shown}", shown).replace("%{total}", items.length)
    }
  }
  document.querySelector("[data-clear-filter]")?.addEventListener("click", () => {
    if (filter) filter.value = ""
    applyState("all")
    tiles.forEach(tile => tile.setAttribute("aria-pressed", "false"))
  })
  tiles.forEach(tile => tile.addEventListener("click", () => applyState(tile.dataset.stateFilter)))

  const filter = document.querySelector("[data-agenda-filter]")
  filter?.addEventListener("input", () => {
    const needle = filter.value.trim().toLowerCase()
    items.forEach(item => {
      const summary = item.querySelector("summary").textContent.toLowerCase()
      item.hidden = needle !== "" && !summary.includes(needle)
    })
    report(needle === "")
  })
}
