# brussels.wtf public + review UI prototype

> **Throwaway prototype for GitHub issue #10.** This is not production Phoenix code and all council records, people, companies, dates, identifiers, and source links are fictionalized prototype data.

Run from the repository root:

```sh
python3 -m http.server 4173 --directory prototypes/ui
```

Then open <http://localhost:4173/?variant=timeline&lang=en>. Timeline is the selected default; the other variants remain available for comparison.

## What to compare

- `?variant=ledger` — compact municipal register
- `?variant=briefing` — numbered editorial briefing with context rail
- `?variant=timeline` — chronological civic timeline
- `&mode=review` — assumed review inbox and source/extracted-text detail
- `&lang=fr-be`, `&lang=nl-be`, or `&lang=en` — language state and core interface copy

The bottom switcher preserves mode and language in the URL. Commune selections persist only in browser `localStorage`; all four are selected on first visit. Story links use agenda-item hashes within a simulated meeting detail view on the same static route.

## Prototype boundary

No dependencies, backend, authentication, network calls, or server-side persistence are used. Review actions and public suggestions are simulations and deliberately do not submit or store data. The inbox → side-by-side review flow is an explicit prototype assumption, not a settled product decision.
