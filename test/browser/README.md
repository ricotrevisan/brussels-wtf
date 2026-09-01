# Real browser test

The ExUnit test pins its Python Playwright dependency in `pyproject.toml` and `uv.lock` and runs it with `uv`. Install Playwright’s matching Chromium for CI with:

```sh
uv sync --project test/browser --frozen
uv run --project test/browser --frozen playwright install chromium
mix test.browser
```

Set `PLAYWRIGHT_CHROMIUM_EXECUTABLE=/usr/bin/chromium` to use an explicitly provisioned system Chromium instead. The test owns its temporary browser profile, shares the SQL sandbox with the real Bandit server, and removes the profile after completion.
