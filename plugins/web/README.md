# web

Connects browser tabs to Tuna over HTTP: serves the page and Tuna's page module, runs each tab's input in the order the tab sent it, hands each upload to its handler on a server thread, and streams each tab's screen as Datastar morphs. A client's page can also be Scheme code, which receives the same screens, calls and questions as procedure calls.

`src/web/page/datastar.js` is Datastar's `bundles/datastar.js`, copied unmodified from https://github.com/starfederation/datastar at tag `v1.0.4`, commit `1efcdc3cb336ec3e9139491604e770e0329657bc`.
