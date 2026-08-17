export function enhanceCommuneSelection(window, document, localStorage) {
  const form = document.querySelector("[data-reader-communes]")
  if (!form) return

  const storageKey = "brussels.wtf:communes"
  const checkboxes = [...form.querySelectorAll('input[name="commune[]"]')]
  const query = new URL(window.location.href).searchParams
  const submitted = query.has("communes_submitted") || query.getAll("commune[]").length > 0

  const selectedValues = () => checkboxes.filter(input => input.checked).map(input => input.value)
  const apply = selected => {
    const visible = new Set(selected)
    checkboxes.forEach(input => input.checked = visible.has(input.value))
    document.querySelectorAll("[data-commune]").forEach(entry => {
      entry.hidden = !visible.has(entry.dataset.commune)
    })
  }

  if (submitted) {
    localStorage.setItem(storageKey, JSON.stringify(query.getAll("commune[]")))
  } else {
    try {
      const stored = JSON.parse(localStorage.getItem(storageKey))
      if (Array.isArray(stored)) apply(stored)
    } catch (_error) {
      localStorage.removeItem(storageKey)
    }
  }

  form.addEventListener("change", () => {
    const selected = selectedValues()
    localStorage.setItem(storageKey, JSON.stringify(selected))
    apply(selected)
  })
}
