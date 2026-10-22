# Research: per-tab state in idiomatic Datastar (for Tuna multi-tab)

Read-only research, 2026-10. Sources: vendored Datastar docs (`agents/reference/datastar/docs.md`, v1.0.4 docs, fetched 2026-10-11), Tuna's bundled `plugins/web/web/datastar-v1.0.2.js`, Hyperlith checkout `/home/jay/Code/hyperlith` (commit `34dbe2e`, 2026-08-07), the local Datastar Discord export (`/home/jay/Code/datastar-discord-export`), GitHub issues, and MDN.

Labels: **[doc]** documented fact, **[code]** read from source, **[author]** a Datastar core-team statement on Discord (Delaney Gillilan = creator; Anders Murphy = core contributor and Hyperlith author), **[community]** other Discord users, **[inference]** my conclusion.

## Summary

- The Datastar way is to keep state on the backend and use signals sparingly, for interaction and for sending input to the backend. Per-tab state belongs on the server, keyed by a session cookie plus a tab id. The browser holds only the cookie, a tab-id signal and the measured facts the server needs (viewport size, scroll position). This is Anders Murphy's stated practice and how Hyperlith works. Delaney's own default is per-user state; he accepts per-tab state when a use case needs it ("send down a uuid signal on the page load, use that as per tab").
- Hyperlith's pattern fits Tuna's model. The shell page creates `tabid` on the client with `crypto.randomUUID()` in a `data-signals` attribute. Every Datastar request, including the long-lived screen-stream request, sends that signal. The server reads `(sid, tabid)` on every request and stores per-tab rows (scroll x/y, viewport w/h, jump target) in the database. Each open stream re-renders `view = f(db, sid, tabid)` after every batch. Nothing is stored per connection. On reload the tab gets a **new** tabid, so per-tab state is deliberately ephemeral. Hyperlith does not use `sessionStorage`.
- Datastar details that affect multi-tab Tuna:
  - Tuna's input goes through a hand-written `fetch`, so it gets no signals automatically. The tab id must be added to that body or to a header.
  - With `openWhenHidden: false` (the GET default), hidden tabs drop their stream and reopen it when shown again.
  - Tuna's v1.0.2 bundle resends **initial** signals on an error retry. This was fixed in v1.0.3. A constant tab id is unaffected.
  - Chrome's "Duplicate tab" copies `sessionStorage`. If the tab id is kept there to survive reloads, duplicate tabs end up sharing an id unless that case is detected.

## 1. What Datastar's docs and authors say about state placement

1. **[doc] The backend is the source of truth.** "In a hypermedia approach, the backend drives state to the frontend and acts as the primary source of truth" (`docs.md:323`). Also "the backend drives state to the frontend and acts as the single source of truth, determining what actions the user can take next" (`docs.md:973`).
2. **[doc] Tao of Datastar** (`docs.md:1480-1536`):
   - "Most state should live in the backend… the backend should be the source of truth" (`:1490`).
   - "Use Signals Sparingly… Overusing signals typically indicates trying to manage state on the frontend… *only* use signals for user interactions (e.g. toggling element visibility) and for sending new state to the backend" (`:1500-1502`).
   - "In Morph We Trust": fat morphs, all the way up to `<html>` (`:1504`).
   - Start with the defaults (`:1492-1494`).
   - Brotli-compress the SSE stream (`:1512`).
3. **[doc] CQRS** means one long-lived read request plus many short-lived write requests: "a single long-lived request to receive updates from the backend (reads), while making multiple short-lived requests to the backend (writes)" (`docs.md:1528-1539`, example `data-init="@get('/cqrs_endpoint')"`). The docs do not say whether this is per tab or per user. A stream is per page instance by construction (next item).
4. **[author] A stream is per tab, never per session.** Anders, 2026-08-03: "You can't really do stream per session… You at most do stream per tab." ([link](https://discord.com/channels/1296224603642925098/1296225449260879973/1533814561608831086))
5. **[doc] Local signals.** Signals beginning with `_` are not sent to the backend by default (`docs.md:977`, `:2187`, `:2603`). The default `filterSignals.exclude` is `/(^_|\._).*/` (`:2683`); the v1.0.2 bundle uses `/(^|\.)_/` [code]. All other signals are sent with **every** request. The docs say this is by design and do not recommend partial sends (`:977-979`). GET requests carry them as the `datastar` query parameter; other methods carry them as a JSON body (`:2605`).
6. **[author] Anders on signals vs server state** (Hyperlith README, `/home/jay/Code/hyperlith/README.md:49-67`):
   - "Signals should only be used for ephemeral client side state… current value of a text input, whether a popover is visible, current csrf token, input validation errors."
   - "View only signals… should be made 'local' by starting their key with an `_`."
   - "Actions should not update the view themselves directly", because the next render overwrites them.
   - "The only way for actions to affect the view returned by the render-fn… is via the database… there is no connection state that needs to be persisted."
7. **[author] Anders on Discord, per-tab state on the server:**
   - "It's easier to put your tab state in your db and look up with tab id." (2025-08-23, [link](https://discord.com/channels/1296224603642925098/1296225449260879973/1408866004095729724))
   - "Look up view data on session token + tab-id." ([link](https://discord.com/channels/1296224603642925098/1296225449260879973/1408870489283236013))
   - "tab state ends up being on the server the minute you do something like virtual scroll so why have it in two places." ([link](https://discord.com/channels/1296224603642925098/1296225449260879973/1408880640610402454))
   - "the client is mostly a session cookie, a csrf token, a tab-id and some contextual data the server wants to know (view height/width x/y scroll)." ([link](https://discord.com/channels/1296224603642925098/1296225449260879973/1408883726082900139))
   - "isolate your tab state on the server by tab id. Then each tab can be different." 2026-02-04. When asked why not fat-morph from the action instead, he answered: "because that doesn't work the minute you have out of bounds updates." ([link](https://discord.com/channels/1296224603642925098/1296225449260879973/1468645860354035925))
   - "Yeah, store for each tab. That's what I do." and "I already have data per tab anyway for virtual scroll." He does not garbage-collect it; he would clear tab rows older than a year, because "the user must expect it to be ephemeral otherwise it would be session data" (2025-11-05, [link](https://discord.com/channels/1296224603642925098/1333801016642244739/1435639779940372531), [link](https://discord.com/channels/1296224603642925098/1333801016642244739/1435643924407521300)).
   - "keep all state (including tab state in sqlite/LMDB)" and "Having tab, session, global state be queriable/joinable and persistent makes things so much easier" (2026-03-24, [link](https://discord.com/channels/1296224603642925098/1333801016642244739/1485952800327205005); 2026-02-27, [link](https://discord.com/channels/1296224603642925098/1333801016642244739/1476853545348370506)).
8. **[author] Delaney prefers per-user state but accepts per-tab state:**
   - "why do you have state per tab and not per user?" and "do a unique signal per tab if you really need it, seems dumb though" (2025-03-08, [link](https://discord.com/channels/1296224603642925098/1296225449260879973/1348008783732932728), [link](https://discord.com/channels/1296224603642925098/1296225449260879973/1348009037148459038)).
   - "explain to me the use case of needing state per tab please" and "either way... send down a uuid signal on the page load, use that as per tab" (2025-05-23, [link](https://discord.com/channels/1296224603642925098/1296225449260879973/1375265692110032956)).
   - **[inference]** Tuna has the use case: each tab has its own frame and viewport (ADR 13 already anticipates "per-tab frames").
9. **[community] Others use the same pattern:**
   - lllama: "I do a stream per tab… I stick a random tabID signal into my html" and "the handler listens for global, page, user/session, and tab updates" (2026-08-03, [link](https://discord.com/channels/1296224603642925098/1296225449260879973/1533839007568494794)).
   - romshark (Datapages) generates a crypto-random, ideally HMAC-signed `tab_id` signal in the GET, and every action validates it ([link](https://discord.com/channels/1296224603642925098/1464634812135505940/1483491979928010862)).
   - Meliketoast: key topics by tab id, not by connection, "cus an connection is kinda ephemeral, the tab isn't" ([link](https://discord.com/channels/1296224603642925098/1532246945949552801/1537122231828873306)).

## 2. How Hyperlith handles sessions and tabs

All paths below are under `/home/jay/Code/hyperlith`. **[code]**

1. **Session.** The session is a `__Host-sid` cookie: random, `Secure; HttpOnly; SameSite=Lax` (`src/hyperlith/impl/session.clj:11-12`). A GET without a sid receives a new one (`:30-40`). Non-GET requests without a sid, or that are not `Sec-Fetch-Site: same-origin`, get 403 (`:20-28`, `:42-46`). Every request is handed to the handler with `:sid` and `:tabid (:tabid body)`, so the tab id is read from the **JSON signals body** (`:28`, `:33`).
2. **Tab id.** The shell page contains `[:div {:data-signals:tabid "self.crypto.randomUUID().substring(0,8)"}]` (`impl/datastar.clj:50-53`, `:69`). The comment reads: "Higher collision risk is acceptable here as it only needs to be unique against a given users other tabs." Anders: "actually I gen the tab id on the client" ([link](https://discord.com/channels/1296224603642925098/1333801016642244739/1422580071620677672)). It is used "for tab-ids so I can have a single landing shim that's shared accross all pages" ([link](https://discord.com/channels/1296224603642925098/1296225503610671224/1423036543760597122)).
3. **Reload behavior.** The id is not stored anywhere (no `data-persist`, no `sessionStorage`), so a reload or a new tab evaluates the expression again and gets a fresh tabid. **[inference]** After a reload, per-tab state starts empty. A duplicated tab also gets a fresh id, because only its sessionStorage is copied and Hyperlith does not use sessionStorage.
4. **Stream request.** The stream is a **POST** to the page's own URL. Its `data-init` is `@post(path + '?u=', {retryMaxCount: Infinity, openWhenHidden: false, retry: 'error'})`, and the same expression is bound to `data-on:online__window` (`impl/datastar.clj:40-48`, `:70-74`). The `u=` query parameter avoids per-URL cache collisions between the GET and POST requests. Because a POST carries signals in its body, the stream request carries `tabid`. **[inference]** `openWhenHidden: false` is set explicitly because non-GET methods default to `true` (`docs.md:2688`).
5. **One render closure per connection, rendered per tab.** `render-handler` registers one render closure per open stream in a `ConcurrentHashMap conns` (`impl/datastar.clj:112-162`).
   - The closure calls `(render-fn req)` with the original request, so `sid` and `tabid` are fixed for that stream.
   - It renders only when the previous put has been delivered, which gives back-pressure and frame dropping (`:137-146`).
   - When the stream closes, the closure removes itself and calls `on-close` (`:147-152`).
6. **Actions are batched; every stream re-renders.** An action returns 204 (`impl/datastar.clj:93-99`) and enqueues a transaction thunk with `tx!`. A batch loop drains the queue every `batch-tick-ms`, which defaults to 50 (`core.clj:117-144`, `:146-148`), runs the batch, then invokes **every** connection's render (`core.clj:130-133`). There is no per-tab routing of updates. Each stream recomputes its own view from shared database state plus its tab row.
7. **Per-tab vs shared data in `examples/billion_cells/src/app/main.clj`:**
   - Per tab (the session row `{:tabs {tabid {...}}}`, `get-tab-data` and `update-tab-data!` at `:194-209`):
     - scroll `:x :y`, from `handler-scroll` (`:236-243`)
     - viewport `:width :height`, from `handler-resize` (`:245-253`)
     - focused cell ids (`:263-281`)
     - jump and share requests with a fresh uid (`:299-311`)
   - Per session: cell focus ownership stored on the chunk as `sid`. The source itself asks "Should this be tab id too?" (`:258-261`, `:276-277`).
   - Shared by everyone: the chunk data (cell values).
   - The view reads `tab-data` for `x y height width` and passes them to the virtual scroller (`:436-479`). `on-close` clears the tab's focus (`:430-431`).
   - The same shape appears in `examples/billion_checkboxes_blob/src/app/main.clj:236-250`, `:256-281`, `:432-440`. There the palette colour is per tab.
   - `game_of_life` keeps only shared state plus `sid` for colour (`examples/game_of_life/src/app/main.clj:82-93`).
8. **Measured facts flow from the browser to the server and back** (`src/hyperlith/extras/ui/virtual_scroll.clj`):
   - On scroll, the browser writes `el.scrollLeft/scrollTop` into signals (`:9-11`). It POSTs only when the position crosses a threshold that needs new rows (`:13-24`, `data-effect` at `:125`).
   - On init, and on window resize debounced by 100 ms, it writes `clientWidth/clientHeight` into signals and POSTs (`:5-7`, `:118-122`).
   - These signals are declared `data-signals__ifmissing` (`:112`), so a fat morph does not reset them.
   - The server stores them per tab and renders the virtual window from them.
   - Server-initiated scrolling ("jump") is sent as a one-shot `execute-expr` element keyed by a new uid that calls `$_view.scroll(...)` (billion_cells `:295-297`, `:520-521`; `impl/datastar.clj:168-170`). `_view` is a local `data-ref` (`:460`).
9. **Shared renders.** README "Work sharing": cache shared view parts after a batch (`README.md:78-82`). `game_of_life` renders the board once into `board-cache` and every connection reuses it (`:142-158`).

## 3. Identity, routing and measured state (answers for Tuna)

1. **How a tab identifies itself.**
   - Idiomatic Datastar: a **non-underscore signal** (`tabid`) that every `@get`/`@post` sends automatically, created on the client (Hyperlith, Delaney's "uuid signal") or on the server in the page HTML (romshark, optionally HMAC-signed). **[doc]+[author]**
   - Tuna specifics **[code]**:
     - The screen stream is `@get('/screen')` on `<html data-init>` (`plugins/web/plugin.ss:336`), so a `tabid` signal would arrive in the `datastar` query parameter.
     - Input is posted by `tuna-input.js` with raw `fetch('/commands', {body: JSON.stringify({...e, version:1, sequence:++F})})`, which sends **no** signals (`plugins/web/web/tuna-input.js`, first function).
     - `/applied` is a Datastar `@post` and already sends signals (`plugin.ss:129-130`).
   - **[inference]** The input plugin must put the tab id in the body or a header itself, for example by reading the signal through Datastar's API or receiving it at init.
2. **One stream per tab, routed by `(session?, tabid)`.**
   - Hyperlith never pushes to a specific tab. Every stream recomputes its view from shared state plus its tab row whenever anything changes. **[code]**
   - **[inference]** For Tuna, this maps to: each `/screen` stream is bound to a tab record (frame, per-tab view state, input numbering), and each redisplay renders one screen per attached tab.
   - The current single `self.next`/`self.pending` input numbering (`plugin.ss:505-520`) and the global stream counter would become per-tab fields.
   - Tuna's existing `stream` number in `/applied?stream=` is per **connection**. Community advice is to key by tab, not connection, because a tab outlives its connections. **[community]**
3. **Measured facts vs server-owned state.**
   - Pattern **[code]+[author]**:
     - The browser measures (scroll offsets, viewport size) and reports; Hyperlith uses signals plus a POST.
     - The server **stores** the measurement per tab and renders from it.
     - Server-initiated moves are one-shot instructions in the morph.
     - Signals hold only the in-flight measurement, declared `__ifmissing` so morphs do not clobber them.
   - This matches Tuna's ADR 15 (the browser reports measured scroll facts; the server places items). **[inference]**
   - What changes for multi-tab: scroll state that is per view today becomes per (tab, view), because two tabs showing the same view have different viewports. Buffer and text state stays shared.
   - The owner's intuition "local state typically lives in signals" holds only for transient, in-flight browser facts. Datastar's authors persist the meaningful per-tab state server-side, keyed by tab id, which also matches the owner's wish for server-side persistence. **[inference]**
4. **Persisting per-tab state across reloads.**
   - Hyperlith deliberately does not: the tab id is new per page load, and per-tab rows are treated as ephemeral. **[code]+[author]**
   - Options if Tuna wants a reloaded tab to keep its frame **[community]+[doc]**:
     - (a) Keep the tab id in `sessionStorage`. Datastar Pro's `data-persist__session`, `docs.md:2353-2381`, does this; Benny used `data-signals__ifmissing` plus `data-persist__session` ([link](https://discord.com/channels/1296224603642925098/1333801016642244739)). Tuna could also use a few lines in its own input plugin, since Pro is a paid add-on.
     - (b) Put the frame in the URL. Tao "Page Navigation"/"Browser History" (`docs.md:1516-1526`) favours URL-addressable pages.

## 4. Datastar mechanics that matter for multi-tab

1. **Signals on every request [doc][code].** All non-`_` signals go with every `@get`/`@post` (`docs.md:977`, `:2603`). GET puts them in the `datastar` query parameter; others in a JSON body (v1.0.2 bundle: `ot(t)?Y.body=F:U.set("datastar",F)`). Raw `fetch` sends nothing.
2. **`openWhenHidden` [doc][code].**
   - Defaults to `false` for GET and `true` for other methods (`docs.md:2688`; bundle `Te(e,t,n=!0)` with `openWhenHidden:h=n`).
   - When it is false, Datastar aborts the stream on `visibilitychange` to hidden and reopens it when the page is visible again (`docs.md:2607`; bundle installs a `visibilitychange` listener).
   - Anders recommends keeping the default: it "forces your app to actually handle the unhappy path" ([link](https://discord.com/channels/1296224603642925098/1296225449260879973/1487560531006062644)).
   - **[inference]** For Tuna, a background tab has no stream. Its tab record must outlive the connection, and on reconnect the tab gets the newest screen (immediate mode gives this for free). Tab liveness should not be inferred from stream presence.
3. **Retry and reconnect [doc][code].**
   - Defaults: `retry: 'auto'` (network errors only), interval 1 s ×2, at most 30 s apart, and `retryMaxCount` 10, after which Datastar gives up (`docs.md:2690-2694`).
   - Hyperlith uses `retryMaxCount: Infinity, retry: 'error'` and re-opens the stream on `online`.
   - The bundle resends `last-event-id` if the server sets SSE ids. Anders' trick: encode state in the event id and receive it back on reconnect ([#900 comment](https://github.com/starfederation/datastar/issues/900)).
4. **Stale signals on retry (version-sensitive) [doc].**
   - Through v1.0.2, an error or server-close retry resends the signal values from the **original** request. A visibility reopen sends current values.
   - Fixed in **v1.0.3** ([#1174](https://github.com/starfederation/datastar/issues/1174), closed 2026-06-21, "Released in v1.0.3"; earlier [#900](https://github.com/starfederation/datastar/issues/900)).
   - Tuna embeds v1.0.2 (`plugins/web/web/datastar-v1.0.2.js`).
   - **[inference]** A constant tab id is unaffected. Measured facts sent as stream-request signals would be stale after a retry, which is another reason to report them as commands rather than via the stream request.
5. **`data-init` [doc].** It runs "on page load, when an element is patched into the DOM, and any time the attribute is modified" (`docs.md:1851-1853`). A retry re-sends only the fetch; it does not re-run the `data-init` expression (bencroker in #900). **[inference]** A tab id created in `data-signals` is evaluated once per page load and stays stable across stream retries and visibility reopens.
6. **Request cancellation [doc].** `requestCancellation: 'auto'` cancels an in-flight request to the same URL and method from the same element (`docs.md:2695`). This is per page, so it does not affect other tabs.
7. **Duplicated tabs and `sessionStorage`.**
   - [doc] `sessionStorage` is partitioned per tab, "survives over page reloads and restores", and a page with an opener starts with a *copy* of the opener's storage ([MDN source](https://raw.githubusercontent.com/mdn/content/main/files/en-us/web/api/window/sessionStorage/index.md)).
   - [community, not spec-verified here] Chrome's "Duplicate tab" also copies `sessionStorage` (accepted answer on [Stack Overflow 21463696](https://stackoverflow.com/questions/21463696/duplicate-tab-copying-sessionstorage-in-chrome); [mdn/content#3688](https://github.com/mdn/content/issues/3688); [livestore#377](https://github.com/livestorejs/livestore/issues/377) cites the HTML spec's clone rule).
   - Benny on Discord: tab ids in sessionStorage "can escape if one duplicates a tab" ([link](https://discord.com/channels/1296224603642925098/1333801016642244739)).
   - **[inference]** A tab id persisted in sessionStorage would be shared by the duplicate and its original. Tuna could detect this when two live streams claim the same id and fork a new id for the newer one; or it could avoid persistence and accept a fresh tab on reload, as Hyperlith does.
8. **Cookies are per origin, not per tab [community].** A double-submit CSRF cookie set per page load broke every tab except the newest ([link](https://discord.com/channels/1296224603642925098/1333801016642244739)). **[inference]** Any per-tab token must not be a single cookie. Tuna currently uses no cookie (ADR 10 amendment), so a session cookie would only be needed to separate users or devices, not tabs.

## Contradictions

- Delaney is sceptical of per-tab state ("seems dumb though", "why… not per user?"). Anders and most practitioners keep per-tab state on the server. Both endorse a uuid tab signal when per-tab state is needed.
- romshark argues that fat-morphing from the action response is simpler than per-tab server state. Anders replies that this fails as soon as out-of-band updates exist ([link](https://discord.com/channels/1296224603642925098/1296225449260879973/1468645860354035925)). Tuna has out-of-band updates (timers, other tabs), so Anders' approach applies.
- #900 is closed as fixed in RC.8, but #1174 shows that v1.0.2 still sends stale signals on error retries. The fix shipped in v1.0.3.

## Missing evidence

- No official data-star.dev page discusses per-tab vs per-user state; the guidance is on Discord and in Hyperlith.
- Firefox and Safari behavior on "Duplicate tab" and `sessionStorage` was not verified.
- The `Discord` link for Benny's sessionStorage/CSRF messages is cited at channel level (the message ids were not extracted).
- Hyperlith's `:render-on-connect` option (billion_cells `:432`) is not read by `render-handler` at this commit, so its effect is unknown.

## Next steps

- Decide whether a reloaded tab keeps its frame. If it does, it needs a sessionStorage or URL tab id plus duplicate-tab handling. If not, use a fresh id per load, as Hyperlith does.
- Consider upgrading the bundled Datastar to ≥ v1.0.3 before relying on signals sent with stream retries.
