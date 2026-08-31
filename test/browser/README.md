# Real browser test

The ExUnit test pins its Python Playwright dependency in `requirements.txt` and runs it with `uv`. Install Playwright’s matching Chromium for CI with:

```sh
uv run --with-requirements test/browser/requirements.txt playwright install chromium
mix assets.build
mix test test/brussels_wtf_web/personal_feed_browser_test.exs
```

Set `PLAYWRIGHT_CHROMIUM_EXECUTABLE=/usr/bin/chromium` to use an explicitly provisioned system Chromium instead. The test owns its temporary browser profile, shares the SQL sandbox with the real Bandit server, and removes the profile after completion.
