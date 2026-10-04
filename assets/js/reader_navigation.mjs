// Resource identity is stable across languages; fragments identify the item being read.
const resultPaths = new Set(['/', '/coverage/coming-up', '/coverage/awaiting-outcome', '/coverage/decisions', '/mandates'])
const normalizedPath = path => path.replace(/\/+$/, '') || '/'

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
    const path = normalizedPath(current.pathname)
    if (resultPaths.has(path)) storage.setItem('brussels.wtf:return', path + current.search)
    const saved = storage.getItem('brussels.wtf:return')
    if (saved) {
      const target = new URL(saved, current)
      const path = normalizedPath(target.pathname)
      if (target.origin === current.origin && resultPaths.has(path)) {
        target.searchParams.set('lang', document.documentElement.lang || 'en')
        document.querySelectorAll('[data-reader-back]').forEach(link => link.href = path + target.search)
      }
    }
  } catch (_) { /* Reading also works when browser storage is disabled. */ }
}
