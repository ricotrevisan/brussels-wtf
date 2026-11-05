# ADR 0007: Let the provider account cap paid coverage

- Status: accepted
- Date: 2026-11-05
- Decision: Rico, in-session 2026-11-05

## Context

Paid coverage had two app-side caps: a monthly hard limit (`COVERAGE_MONTHLY_BUDGET_CENTS`, 1000 cents in production) and a per-stage `provider.max_price` sent to OpenRouter. The price cap made each reservation a true maximum, which kept the hard limit sound.

On 2026-11-05 every endpoint of the primary model, `deepseek/deepseek-v4.1-flash`, listed $0.50/M output against its $0.30/M cap, so OpenRouter refused it and generation ran on fallbacks. On 2026-11-04 the OpenRouter account, shared with other projects, ran out of credit; calls failed with HTTP 402 and pages stayed stranded until someone noticed.

Rico has spending limits on the OpenRouter account and key. Duplicating them in the app caused outages without protecting anything the account limits do not.

## Decision

- `COVERAGE_MONTHLY_BUDGET_CENTS` becomes optional in paid mode. Unset, the month is a ledger: calls still reserve an estimate and settle, nothing is refused for budget, and a call settles at its actual cost even above its estimate.
- Per-stage `max_price` is sent only while a monthly limit is set. A configured limit keeps the old, sound behaviour.
- A 402 is classified `provider_credit_exhausted`. The page reports it at once in one publication case instead of burning retries, and a credit check runs.
- `BrusselsWtf.ProviderCredit` reads `GET /api/v1/key` and `GET /api/v1/credits` hourly with the ordinary key. It alerts Rico in Discord #brussels-wtf through Drummer's `brussels-wtf-alerts` webhook route once per change (low below `OPENROUTER_LOW_CREDIT_CENTS`, default 500; exhausted; recovered). When credit is back it queues one publish job per stranded page; those reuse succeeded locales (issue 159).

## Consequences

- The app no longer bounds spend. The account and key limits do, and the ledger still records every call's actual cost for review.
- With no price cap, throughput routing may choose a pricier endpoint of a pinned model. Model choice stays pinned in code.
- Removing the limit on a month already created with one clears its stored limit; spend recorded so far is kept.
- An alert that cannot be delivered is retried by the next check, because the last notified state only advances on delivery.
