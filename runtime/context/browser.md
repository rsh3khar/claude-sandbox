## Browser / UI Testing

Browser is **opt-in** — enable it from the launch menu. When enabled, this sandbox includes a **headless Chromium browser** via Playwright. The Chromium binary is cached in a Docker volume, so only the first launch downloads it.

If you need the browser but it wasn't enabled at launch, **exit and restart the sandbox** with the browser option — volumes can't be mounted to a running container.

### MCP Browser Tools (Claude Code)

Playwright MCP is auto-configured when browser is enabled. Available tools:
- `browser_navigate` — Go to a URL (e.g. `http://localhost:3000`)
- `browser_screenshot` — Capture what's on screen
- `browser_click` — Click an element by selector
- `browser_type` — Type text into inputs
- `browser_hover`, `browser_select_option` — Other interactions
- `browser_console_messages` — View console output

Just ask to navigate or screenshot a page — the tools are available automatically.

### Python Playwright (Claude Code + Codex)

The `playwright` Python package is pre-installed:

```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(
        headless=True,
        args=['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu']
    )
    page = browser.new_page()
    page.goto('http://localhost:3000')
    page.wait_for_load_state('networkidle')
    page.screenshot(path='screenshot.png')
    browser.close()
```

**Container args required**: Always include `args=['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu']`.

The `webapp-testing` skill has helper scripts for managing server lifecycle — use it for complex scenarios.
