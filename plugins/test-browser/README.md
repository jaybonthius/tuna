# test-browser

A pretend user at a real browser page: opens pages of the Chromium on the `PATH` at Tuna's `web`, each a client, presses keys and types in them, and waits until a page has applied what Tuna sent it, so a test reads the page's DOM and computed styles through chez-cdp. Tests import it; no plugin does.
