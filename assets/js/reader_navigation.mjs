// Resource identity is stable across languages; fragments identify the item being read.
export function enhanceReaderNavigation(window, document, storage) {
  const current = new URL(window.location.href)
  document.querySelectorAll('a[hreflang]').forEach(link => {
    const target = new URL(link.href, current)
    if (target.origin === current.origin && target.pathname === current.pathname) {
      target.hash = current.hash
      link.href = target.href
    }
  })
  try {
    storage ??= window.sessionStorage
    if (current.pathname === '/') storage.setItem('brussels.wtf:return', current.pathname + current.search)
    const saved = storage.getItem('brussels.wtf:return')
    if (saved) {
      const target = new URL(saved, current)
      if (target.origin === current.origin && target.pathname === '/') {
        target.searchParams.set('lang', document.documentElement.lang || 'en')
        document.querySelectorAll('[data-reader-back]').forEach(link => link.href = target.pathname + target.search)
      }
    }
  } catch (_) { /* Reading also works when browser storage is disabled. */ }
}
