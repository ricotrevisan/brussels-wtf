// Preferences enhance native GET forms; the server must select before capping previews.
export function enhanceCommuneSelection(window, document, storage) {
  const form = document.querySelector("[data-reader-communes]")
  if (!form) return

  const storageKey = "brussels.wtf:communes"
  const checkboxes = [...form.querySelectorAll('input[name="commune[]"]')]
  const allowed = new Set(checkboxes.map(input => input.value))
  const normalize = values => [...new Set(values.filter(value => allowed.has(value)))]
  const current = new URL(window.location.href)
  const query = current.searchParams
  const explicit = query.has("communes_submitted") || query.has("commune[]") || query.has("commune")
  const remember = selected => {
    try { (storage ?? window.localStorage).setItem(storageKey, JSON.stringify(selected)) }
    catch (_) { /* Browser storage is optional; native GET still works. */ }
  }

  if (explicit) {
    remember(normalize([...query.getAll("commune[]"), ...query.getAll("commune")]))
  } else {
    let stored
    try { stored = JSON.parse((storage ?? window.localStorage).getItem(storageKey)) }
    catch (_) { /* Invalid or unavailable storage leaves the all-communes baseline. */ }
    if (Array.isArray(stored)) {
      const selected = normalize(stored)
      if (stored.length === 0 || selected.length > 0) {
        query.set("communes_submitted", "1")
        selected.forEach(value => query.append("commune[]", value))
        window.location.replace(current.href)
        return
      }
    }
  }

  form.addEventListener("submit", () => {
    remember(checkboxes.filter(input => input.checked).map(input => input.value))
  })
}
