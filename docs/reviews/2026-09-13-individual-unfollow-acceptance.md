# Individual registered unfollow

Implements [Add individual unfollow controls for registered citizens](https://github.com/RicoTrevisan/brussels-wtf/issues/54)
on the existing registered authentication and follow foundation.

Signed-in citizens see their followed state and an ordinary POST unfollow control
on dossiers, people, companies, commune filters, and the registered feed. The
feed lists active follows even when they have no deliveries. French, Dutch and
English explain that unfollow stops new updates while previously received updates
and read state remain until their existing twelve-month expiry. Personalized
responses are private and cannot be cached by shared caches.

The endpoint selects through the citizen-scoped Ash `mine` action and removes
through its authorized `remove` action. Repeating removal, submitting another
citizen's follow ID, and submitting a nonexistent UUID have the same successful
response for an authenticated citizen; none exposes another citizen's state.
Anonymous direct Ash removal is denied and browser mutations require CSRF.

Synchronization locks and rechecks each follow row inside an Ash transaction.
Deletion uses PostgreSQL's conflicting row lock: an already executing publication
commits before removal succeeds; a worker holding a stale follow selection skips
it after removal commits. Retained history, other follows and public facts are
not deleted by removal. Following again revalidates received history against the
public projection without backfilling updates from the unfollowed interval.
Existing publication eligibility and retention cleanup still apply.

## Acceptance evidence

- `follow_registered_test.exs`: direct Ash isolation, ordinary idempotent removal,
  unrelated follows, retained read state, and ordinary expiry.
- `unfollow_concurrency_test.exs`: independent committed database connections,
  controlled publication barrier, both lock orderings and retained history.
- `registered_feed_browser_test.exs` / `test/browser/registered_feed.py`: managed
  Chromium follows all four real public fixture types, receives authoritative
  events, preserves read state across sign-ins, checks all three locales,
  removes from every public surface and the feed, repeats removal, tests missing
  CSRF and another citizen's HTTP request, and follows again without losing history.
  Mobile and desktop dossier checks include overflow assertions and screenshots.

This implements the individual-unfollow release gate. It does not deploy the
application or waive other production rollout requirements. All published facts
used by these tests are isolated synthetic fixtures.

## Verification results

Against dedicated local test databases:

- `ERL_FLAGS='+S 4:4' MIX_TEST_PARTITION='_issue54' mix test`:
  445 tests, zero failures, 27 excluded external/browser tests.
- `ERL_FLAGS='+S 4:4' MIX_TEST_PARTITION='_issue54_browser' mix test.browser`:
  five managed-Chromium tests, zero failures.
- The final action filter was also verified through the registered Chromium journey
  and the eleven registered-domain/concurrency tests.
- Compilation with warnings as errors, formatting and `git diff --check` pass.
- Impeccable's mechanical detector reported no findings; dossier screenshots at
  390px and 1280px were visually inspected.
