# Municipal polling operations

[#20: Schedule polling with finite retries and observability](https://github.com/RicoTrevisan/brussels-wtf/issues/20) makes polling requests durable before Oban executes them. PostgreSQL owns locator due times; cron only starts fixed commune and delayed-record index checks.

## Fixed schedules

- Current commune indexes: every six hours, staggered at minutes `0`, `15`, `30`, and `45` for Ixelles, Uccle, Forest, and the City of Brussels.
- Previous-year delayed-record checks: daily at `01:05`, `01:20`, `01:35`, and `01:50`.
- Meeting locators: every six hours from 30 days before through 30 days after the meeting.
- Older meeting locators: daily through day 180, stopping earlier when a final record has not changed for 30 days.
- Historical backfill: never scheduled; it is an explicit authenticated operation.

Cron entries exist for all four communes. A cron wrapper records an `adapter unavailable` metric and exits safely until that commune's explicit adapter is implemented; it does not create recurring failed polls or review cases.

`source_locators.next_fetch_at` is authoritative. No locator URL is represented by a dynamic cron entry.

## Poll now and backfill

Sign in to `/review` and use **Operational polling**. Choose `poll-now` or `backfill`, a target type, and the target ID. Supported targets are commune, index, meeting, and locator.

The request records the reviewer, target, kind, status, and stable check key before queue insertion. Poll-now and backfill checks do not change the standing `next_fetch_at` schedule. Scheduled checks advance or stop it according to the policy above.

## Retry and review behavior

One HTTP adapter call creates one retrieval observation. Req's internal retry behavior is disabled.

Transient transport failures and HTTP 408, 425, 429, and 5xx responses receive six finite, deterministically jittered delays around 30 seconds, 2 minutes, 10 minutes, 1 hour, 6 hours, and 24 hours. A valid `Retry-After` value is the minimum delay. Newly discovered 404 responses retry; a known locator returning 404 is recorded as disappeared.

Authentication failure, corrupt archives, invalid content, parser ambiguity, unsupported media, and repeated extraction quality failure stop automatically and open one review case per processing generation. Exhausting transient retries does the same.

## Observability

Structured logs and telemetry correlate by poll run, retrieval observation, locator, source version, and review case. Events cover:

- poll duration and queue age;
- retrieval status and changed hashes;
- archived byte counts;
- retry count, attempt, and delay;
- review-case creation;
- stale commune polls and recent failed polls.

Authoritative URLs, query strings, response bodies, credentials, private object keys, and private diagnostics are excluded from telemetry and ordinary structured logs.
