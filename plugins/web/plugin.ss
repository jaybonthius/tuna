#lang :tuna/prelude
;;; Web transport (startup tier): the loopback HTTP server, the page shell,
;;; ordered input over POST /commands, and the screen stream (ADR 7, ADR 10).
;;;
;;; Every page is a tab, a client (ADR 16): serving the page makes a new
;;; tab id, numbered from 1, and the page shell holds it as the `tab`
;;; signal, outside the screen, so Datastar sends it with the screen stream
;;; and /applied, and the input sender adds it to every /commands item. The transport keeps a record
;;; per tab id: its client, its input numbering, and its screens and their
;;; pacing. A reload is a new tab. A tab whose streams have all closed is
;;; forgotten `tab-grace` ms later unless one reopens (Datastar closes a
;;; hidden tab's stream and reopens it when the tab is shown), and
;;; client-gone-hook then runs for its client on the editor loop.
;;;
;;; POST /commands takes one input item: a keydown, a pointer or a scroll
;;; item, each with its tab and its page-load sequence number, validated
;;; strictly into a key-event, a pointer-event or a scroll-event from the
;;; tab's client. Each tab's items are submitted in the order of their
;;; numbers. A page counts from 1 when it loads; a tab id the transport
;;; does not know (the page outlived its tab, or a server restart) has its
;;; numbering start at its first item. Each
;;; screen carries its revision as data-revision on its root element, and
;;; pointer and scroll items name the screen they were computed on, which
;;; must be one this transport sent the tab. The page's actions
;;; (frontend/) measure and report scrolling (tunaScroll) and place a view
;;; where the server asks (tunaPlace).
;;;
;;; Each redisplay renders a screen for each tab that has a stream open, as
;;; that tab's browser shows the editor (the renderer contract), and sends
;;; it when it differs from the tab's last screen or the tab is owed one
;;; for a scroll report. A screen is the renderer's HTML, UTF-8 bytes in
;;; parts, streamed into its event as they are (call-with-patch-elements):
;;; its revision and its data-init are written after its root element's
;;; tag name as it is sent, so no screen is ever copied. Rendering happens on the editor thread only: a
;;; page being served, or a stream that opens, asks the editor loop to
;;; redisplay, and waits for its screen.
;;; Each page's stream sends a screen only once the page has applied the
;;; previous one: every screen carries a data-init that posts /applied when
;;; it is morphed in. So a slow phone or link gets the newest screen, never
;;; a backlog. When the page does not confirm a screen within
;;; `screen-timeout` ms, the newest is sent again, in case it was lost; the
;;; page also needs a screen to put back what it changed itself, such as the
;;; scroll report trigger it removes while a report is on its way.
;;; Rendering still happens only when state changes.
;;;
;;; The page's <head> links every registered stylesheet (the stylesheets
;;; contract), each served at /css/<n>/<hash>/<file>; files beside a
;;; stylesheet are served under the same prefix, so its relative url()s
;;; work. The head is rendered from the registry on the editor thread at
;;; redisplay, published with the screen, and sent whole as one morph
;;; before the screen whenever it differs from what a stream last got.

(import (only-in :gerbil/runtime/hash HashTable)
        (only-in :gerbil/runtime/thread spawn-thread)
        :std/io
        :std/log
        :std/misc/ports
        :std/net/address
        :std/net/http/server
        :std/net/mime/file
        :std/net/uri
        :std/net/url
        :std/text/markup/sxml/print
        (only-in :std/crypto/random random-bytes)
        :std/time/timeout
        :gerbil-datastar/http
        :tuna/kernel
        :tuna/version
        :tuna/lib/plugin-options
        ;; A tab has a field named client, which would shadow the type of
        ;; that name in its constructor.
        (rename-in (only-in :tuna/plugins/clients/contract client make-client client-id client-gone-hook)
                   (client client-type))
        (only-in :tuna/plugins/keys/contract key-event make-key-event pointer-event make-pointer-event
                 scroll-event make-scroll-event
                 posn make-posn)
        :tuna/plugins/renderer/contract
        :tuna/plugins/stylesheets/contract
        :tuna/plugins/web/embed)
(export web-transport
        web-transport-url)

(deflogger web-log name: "tuna/web")

;; Seconds between keep-alive events while there is nothing to send; they
;; also detect closed tabs.
(def heartbeat-seconds 15.)

(def static-assets (embed-directory "web" "/static"))

(defclass web-server
  ((submit      : :procedure)   ; input item -> void; submits to the editor loop
   (port        : :fixnum)
   (host        : :string)      ; the only Host accepted
   (origin      : :string)      ; the only Origin accepted
   (admission   : :mutex)       ; guards each tab's input ordering and submission
   (slot-numbers : HashTable)   ; (owner . name) -> n in /css/<n>/; editor thread only
   (stylesheets-seen : :fixnum) ; the stylesheets generation HEAD shows; editor thread only
   (grace       : :real)        ; seconds a tab without a stream is kept
   (keeper      :? :thread)     ; runs tab-keeping-thread
   (mutex       : :mutex)       ; guards the fields below and each tab's screens
   (changed     : :condvar)
   (tabs        : HashTable)    ; tab id -> web-tab
   (head        : :string)      ; the newest <head>
   (served      : :list)        ; the served-stylesheets HEAD links
   (revision    : :fixnum)      ; the newest revision given to a screen
   (stopped?    : :boolean)
   (streams     : :fixnum)      ; streams opened so far, to number them
   (timeout     : :real)        ; seconds a page may take to confirm a screen
   (server      : :t))
  final: #t)

;; One browser tab, by the id its page made (ADR 16).
(defclass web-tab
  ((client    : client-type)
   ;; Guarded by the server's admission mutex:
   (next      : :fixnum)        ; next page-load sequence to submit
   (pending   : HashTable)      ; sequence -> input item
   (numbered? : :boolean)       ; whether its first item set NEXT
   ;; Guarded by the server's mutex:
   (rendered  : :t)             ; the newest screen for it, the renderer's HTML
   (revision  : :fixnum)        ; RENDERED's revision
   (owed      : :boolean)       ; a scroll report or pointer movement awaits a screen
   (wanted?   : :boolean)       ; a screen must be rendered for it before it is sent one
   (applied   : HashTable)      ; its stream -> last screen count its page applied
   (streams   : :fixnum)        ; its open streams
   (closings  : :fixnum))       ; times its streams all closed; a grace period acts on the latest only
  final: #t)

;; A stylesheet the head links, as request threads serve it: its text, and
;; the files beside it under the same URL prefix.
(defstruct served-stylesheet ((id        : :string)   ; the link's id
                              (prefix    : :string)   ; "/css/<n>/<hash>/"
                              (file      : :string)   ; its file name, URL-encoded
                              (directory : :string)   ; where the files beside it are
                              (bytes     : :u8vector))
  final: #t)

;; Bind and release an ephemeral loopback port.
(def (free-loopback-port) => :fixnum
  (using (socket (tcp-listen (string->address "inet4:127.0.0.1:0")) : ServerSocket)
    (let (address (socket.address))
      (socket.close)
      (:- (InetAddress-port address) :fixnum))))

;; The plain loopback URL of the active web transport.
(def (web-transport-url) => (Maybe :string)
  (let (display (service-provider display-service))
    (and (web-server? display)
         (using (self display : web-server)
           (string-append "http://" self.host "/")))))

;;; Screens

;; The screen for client C. Editor thread only.
(def (render-screen (c : client-type)) => :t
  (let (renderer (service-provider renderer-service))
    (if renderer
      (Renderer-render-screen (Renderer renderer) c)
      no-renderer-screen)))

(def no-renderer-screen (string->utf8 "<main id=\"screen\"><p>No renderer is active.</p></main>"))

;; What a tab shows before a screen was rendered for it; that it shows
;; this very object means none was.
(def empty-screen (string->utf8 "<main id=\"screen\"></main>"))

;; Seconds a page being served waits for the editor loop to render its
;; screen, before it is served without one and its stream brings it.
(def page-render-seconds 2.)

;; What a screen sent as REVISION carries on its root element: as the
;; COUNTth screen sent on STREAM, a data-init telling the page to confirm
;; it once applied (go-latest-frame-spike's /next); then REVISION as
;; data-revision, so that pointer items can name the screen they were
;; computed on (ADR 7). The page's first screen has no data-init.
(def (screen-stamps (revision : :fixnum) (stream :? :fixnum) (count :? :fixnum)) => :u8vector
  (string->utf8
   (string-append
    (if (and stream count)
      (string-append " data-init=\"@post('/applied?stream=" (number->string stream)
                     "&amp;count=" (number->string count) "'); el.removeAttribute('data-init')\"")
      "")
    " data-revision=\"" (number->string revision) "\"")))

;; SCREEN's bytes to OUT, with STAMPS (text with a leading space) after its
;; root element's tag name: before the first space, tab, newline, > or /
;; after its first byte, which must be <; without them when it is not.
(def (write-stamped-screen (out : BufferedWriter) (screen : :t) (stamps : :u8vector)) => :void
  (let ((state 'start)                  ; start, name (in the tag name) or done
        (seen 0))
    (html-for-each
     (lambda ((bytes : :u8vector))
       (let (size (u8vector-length bytes))
         (case state
           ((done) (BufferedWriter-write out bytes))
           (else
            (let (from (cond
                        ((fxzero? size) 0)
                        ((eq? state 'name) 0)
                        ((fx= (u8vector-ref bytes 0) 60) (set! state 'name) 1)
                        (else (set! state 'done) size)))
              (let (end (let lp ((i from))
                          (if (and (eq? state 'name) (fx< i size)
                                   (not (memv (u8vector-ref bytes i) '(32 9 10 62 47))))
                            (lp (fx1+ i))
                            i)))
                (if (and (eq? state 'name) (fx< end size))
                  (begin
                    (BufferedWriter-write out bytes 0 end)
                    (BufferedWriter-write out stamps)
                    (BufferedWriter-write out bytes end size)
                    (set! state 'done))
                  (BufferedWriter-write out bytes))))))
         (set! seen (fx+ seen size))))
     screen)
    ;; A screen that is all tag name: the stamps go at its end.
    (when (and (eq? state 'name) (fx> seen 1))
      (BufferedWriter-write out stamps))))

;; Only the editor loop redisplays, so revisions are assigned in order.
;; It also holds the baton, so it may read the stylesheets registry and
;; render: a screen for each tab with a stream open or wanting one.
(defmethod {redisplay! web-server}
  (lambda (self)
    (using (self : web-server)
      (let* ((served (changed-stylesheets self))
             (head (and served (render-head served)))
             (tabs (do-with-lock self.mutex
                     (filter (lambda ((tab : web-tab)) (or tab.wanted? (fx> tab.streams 0)))
                             (hash-values self.tabs)))))
        (publish-screens! self
                          (map (lambda ((tab : web-tab)) (cons tab (render-screen tab.client))) tabs)
                          head served)))))

;; Give each of SCREENS, (tab . rendered) pairs, the next revision and send
;; it to its tab when it differs from the tab's last screen or the tab is
;; owed a screen, and with HEAD for SERVED stylesheets, when given, to every
;; tab. A screen is drawn only from editor state, so the same screen as a
;; tab's last one means nothing on it changed: that tab is sent nothing.
;; A renderer that saw nothing change returns the very HTML it returned
;; last time, which is told apart without reading it. A page sends one
;; scroll report, or one pointer movement, at a time and waits for a
;; screen before the next, so such a report is always answered with one
;; (paced-report?).
(def (publish-screens! (self : web-server) (screens : :list) (head : :t) (served : :t)) => :void
  (do-with-lock self.mutex
    (when served
      (set! self.head head)
      (set! self.served served))
    (for-each (lambda ((screen : :pair))
                (using (tab (car screen) : web-tab)
                  (let (rendered (cdr screen))
                    (when (or served tab.owed
                              (not (or (eq? rendered tab.rendered) (equal? rendered tab.rendered))))
                      (let (revision (fx1+ self.revision))
                        (set! self.revision revision)
                        (give-screen! tab rendered revision)))
                    (set! tab.wanted? #f))))
              screens)
    (condition-variable-broadcast! self.changed)))

;; Send TAB its last screen again, under a new revision: the answer to a
;; scroll report or pointer movement that no task runs for.
(def (resend-screen! (self : web-server) (tab : web-tab)) => :void
  (do-with-lock self.mutex
    (unless (eq? tab.rendered empty-screen)
      (let (revision (fx1+ self.revision))
        (set! self.revision revision)
        (give-screen! tab tab.rendered revision)
        (condition-variable-broadcast! self.changed)))))

;; Make RENDERED, as REVISION, TAB's newest screen. Call with the server's
;; mutex held.
(def (give-screen! (tab : web-tab) (rendered : :t) (revision : :fixnum)) => :void
  (set! tab.rendered rendered)
  (set! tab.revision revision)
  (set! tab.owed #f))

;; TAB's newest screen as [revision head screen] once STREAM's page has
;; applied its COUNTth screen and one newer than SENT exists, and no
;; screen is being rendered for TAB; the newest again when the page has
;; not confirmed within SELF's timeout; 'heartbeat
;; after heartbeat-seconds of nothing to send; #f once stopped. Never
;; touches editor state, so a slow client never holds up the editor loop.
(def (await-screen (self : web-server) (tab : web-tab) (stream : :fixnum) (sent : :fixnum) (count : :fixnum))
  => :t
  (let (start (time->seconds (current-time)))
    (mutex-lock! self.mutex)
    (let lp ()
      (let* ((applied? (fx>= (: (hash-ref tab.applied stream 0) :fixnum) count))
             (deadline (+ start (if applied? heartbeat-seconds self.timeout)))
             (newest (lambda () (let (newest [tab.revision self.head tab.rendered])
                                  (mutex-unlock! self.mutex)
                                  newest))))
        (cond
         (self.stopped?
          (mutex-unlock! self.mutex)
          #f)
         ((and applied? (not tab.wanted?) (fx> tab.revision sent))
          (newest))
         ((and (>= (time->seconds (current-time)) deadline) (not tab.wanted?))
          (if applied?
            (begin (mutex-unlock! self.mutex) 'heartbeat)
            (newest)))
         (else
          (mutex-unlock! self.mutex self.changed (max 0. (- deadline (time->seconds (current-time)))))
          (mutex-lock! self.mutex)
          (lp)))))))

;; A new page, as a new tab numbered from 1, showing the screen the editor
;; loop renders for it. The server makes the id, not the page, so it knows
;; the tab counts from 1 even when its second item arrives before its
;; first.
(def (new-page (self : web-server)) => :u8vector
  (let (id (new-tab-id))
    (using (tab (do-with-lock self.mutex
                  (let (tab (tab-named! self id))
                    (set! (web-tab-wanted? tab) #t)
                    tab))
                : web-tab)
      (do-with-lock self.admission
        (set! tab.next 1)
        (set! tab.numbered? #t))
      (ask-redisplay! self)
      (let (deadline (+ (time->seconds (current-time)) page-render-seconds))
        (mutex-lock! self.mutex)
        (let lp ()
          (let (left (- deadline (time->seconds (current-time))))
            (if (and tab.wanted? (not self.stopped?) (> left 0))
              (begin
                (mutex-unlock! self.mutex self.changed left)
                (mutex-lock! self.mutex)
                (lp))
              (let (page (page-html id self.head tab.rendered tab.revision))
                (mutex-unlock! self.mutex)
                page))))))))

;; 32 random hex digits.
(def (new-tab-id) => :string
  (apply string-append
         (map (lambda ((b : :fixnum))
                (string-append (if (fx< b 16) "0" "") (number->string b 16)))
              (u8vector->list (random-bytes 16)))))

(def (html-string (markup : :list)) => :string
  (call-with-output-string ""
    (lambda (port) (write-sxml markup port: port xml?: #f))))

;;; Stylesheets

;; The page's stylesheets as served-stylesheets, in page order, when the
;; registry changed since SELF last looked; otherwise #f. Editor thread only:
;; reading the registry updates its generation.
(def (changed-stylesheets (self : web-server)) => (Maybe :list)
  (let (generation (stylesheets-generation))
    (and (not (fx= generation self.stylesheets-seen))
         (begin
           (set! self.stylesheets-seen generation)
           (filter-map (lambda ((s : stylesheet))
                         (and (stylesheet-text s) (serve-stylesheet self s)))
                       (stylesheets))))))

(def (serve-stylesheet (self : web-server) (s : stylesheet)) => served-stylesheet
  (let* ((key (cons (stylesheet-owner s) (stylesheet-name s)))
         (n (or (hash-get self.slot-numbers key)
                (let (n (fx1+ (hash-length self.slot-numbers)))
                  (hash-put! self.slot-numbers key n)
                  n)))
         (path (stylesheet-path s)))
    (make-served-stylesheet
     (stylesheet-link-id (stylesheet-owner s) (stylesheet-name s))
     (string-append "/css/" (number->string n) "/" (: (stylesheet-digest s) :string) "/")
     (uri-encode (path-strip-directory path))
     (path-directory path)
     (string->utf8 (: (stylesheet-text s) :string)))))

;; A stable element id for the stylesheet (OWNER NAME): "css__OWNER__NAME"
;; with every character other than a letter, digit or hyphen written as
;; _XX in hex, so that owners such as PLUGIN/config give a plain id and no
;; two stylesheets share one.
(def (stylesheet-link-id (owner : :symbol) (name : :symbol)) => :string
  (def (escape (text : :string)) => :string
    (apply string-append
           (map (lambda ((c : :char))
                  (if (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9) (char=? c #\-))
                    (string c)
                    (apply string-append
                           (map (lambda ((byte : :fixnum))
                                  (string-append "_" (if (fx< byte 16) "0" "")
                                                 (number->string byte 16)))
                                (u8vector->list (string->utf8 (string c)))))))
                (string->list text))))
  (string-append "css__" (escape (symbol->string owner)) "__" (escape (symbol->string name))))

;; The page's <head>, linking SERVED in order. The first page and every
;; head morph use it, so the scripts it holds stay identical and a morph
;; leaves them alone. The viewport lets a phone's soft keyboard shrink the
;; page, and lets the page reach the screen's edges; the renderer's screen
;; pads itself out of the safe-area insets.
(def (render-head (served : :list)) => :string
  (html-string
   `(head
     (meta (@ (charset "utf-8")))
     (meta (@ (name "viewport")
              (content "width=device-width, initial-scale=1, interactive-widget=resizes-content, viewport-fit=cover")))
     (title "Tuna")
     ,@(map (lambda ((s : served-stylesheet))
              `(link (@ (id ,(served-stylesheet-id s)) (rel "stylesheet")
                        (href ,(string-append (served-stylesheet-prefix s)
                                              (served-stylesheet-file s))))))
            served)
     (script (@ (type "importmap"))
             "{\"imports\":{\"datastar\":\"/static/datastar-v1.0.2.js\"}}")
     (script (@ (type "module") (src "/static/tuna-input.js"))))))

;; File types served beside a stylesheet: fonts, images and CSS.
(def (asset-content-type (path : :string)) => (Maybe :string)
  (let (type (if (equal? (path-extension path) ".webp") "image/webp" (mime-file-type path)))
    (cond
     ((string=? type "text/css") "text/css; charset=utf-8")
     ((or (string-prefix? "font/" type) (string-prefix? "image/" type)) type)
     (else #f))))

;; A relative path of plain segments: no empty segment, no . or .., and no
;; escapes or backslashes that could spell them.
(def (plain-relative-path? (path : :string)) => :boolean
  (andmap (lambda ((segment : :string))
            (and (not (member segment '("" "." "..")))
                 (not (string-index segment #\%))
                 (not (string-index segment #\\))))
          (string-split path #\/)))

;; GET /css/<n>/<hash>/<rest>: the stylesheet itself, cached forever since
;; its hash names its text; or a file beside it, with an ETag. Any prefix
;; that is not current gets 404.
(def (serve-css (self : web-server) (request : Request) (response : ResponseHandler) (path : :string))
  => :void
  (let (s (find (lambda ((s : served-stylesheet)) (string-prefix? (served-stylesheet-prefix s) path))
                (do-with-lock self.mutex self.served)))
    (if s
      (using (s : served-stylesheet)
        (let (rest (substring path (string-length s.prefix) (string-length path)))
          (if (string=? rest s.file)
            (ResponseHandler-write! response OK
                                    '(("Content-Type" . "text/css; charset=utf-8")
                                      ("Cache-Control" . "public, max-age=31536000, immutable"))
                                    s.bytes)
            (serve-asset request response s.directory rest))))
      (respond-text response Not-Found (string-append "Not found: " path)))))

(def (serve-asset (request : Request) (response : ResponseHandler) (directory : :string) (rest : :string))
  => :void
  (let* ((file (and (plain-relative-path? rest) (path-expand rest directory)))
         (type (and file (asset-content-type file)))
         (info (and type (file-exists? file) (file-info file #t))))
    (if (and info (eq? (file-info-type info) 'regular))
      (let (etag (string-append "\"" (number->string (file-info-size info)) "-"
                                (number->string (time->seconds (file-info-last-modification-time info)))
                                "\""))
        (if (equal? (header request "If-None-Match") etag)
          (ResponseHandler-write! response Not-Modified [(cons "ETag" etag)] #u8())
          (ResponseHandler-write! response OK
                                  [(cons "Content-Type" type)
                                   (cons "Cache-Control" "no-cache")
                                   (cons "ETag" etag)]
                                  (read-file-u8vector file))))
      (respond-text response Not-Found (string-append "Not found: " rest)))))

(def (page-html (tab : :string) (head : :string) (screen : :t) (revision : :fixnum)) => :u8vector
  (let (out (open-buffered-writer #f))
    (BufferedWriter-write-string-utf8 out (page-start tab head))
    (write-stamped-screen out screen (screen-stamps revision #f #f))
    (BufferedWriter-write-string-utf8 out "</body></html>")
    (get-memory-output-u8vector out)))

;; The page up to its screen.
(def (page-start (tab : :string) (head : :string)) => :string
  (string-append
   "<!doctype html>"
   "<html lang=\"en\""
   ;; The tab id (ADR 16), outside the screen and before data-init, so the
   ;; stream's first request carries it. TAB is hex digits.
   " data-signals:tab=\"'" tab "'\""
   " data-init=\"@get('/screen')\""
   " data-on:keydown__document__capture=\"@tunaKeyboard()\""
   ;; One pointer action for clicks on release (click, auxclick), for
   ;; presses on chrome that must not move focus (mousedown, contextmenu),
   ;; and for pressing, dragging and releasing in text (mousedown,
   ;; mousemove, mouseup).
   " data-on:mousedown__document=\"@tunaPointer()\""
   " data-on:mousemove__document=\"@tunaPointer()\""
   " data-on:mouseup__document=\"@tunaPointer()\""
   " data-on:contextmenu__document=\"@tunaPointer()\""
   " data-on:click__document=\"@tunaPointer()\""
   " data-on:auxclick__document=\"@tunaPointer()\">"
   head
   ;; The renderer's HTML is already escaped.
   "<body>"))

;;; Requests

(def (header (request : Request) (name : :string)) => (Maybe :string)
  (let lp ((rest (Request-headers request)))
    (match rest
      ([[key . value] . more]
       (if (string-ci=? key name) value (lp more)))
      (else #f))))

(def (string-trim-spaces (text : :string)) => :string
  (let* ((end (string-length text))
         (start (let lp ((i 0)) (if (and (fx< i end) (char=? (string-ref text i) #\space)) (lp (fx1+ i)) i)))
         (stop (let lp ((i end)) (if (and (fx> i start) (char=? (string-ref text (fx1- i)) #\space)) (lp (fx1- i)) i))))
    (substring text start stop)))

(def (respond-text (response : ResponseHandler) (status : Status) (text : :string)) => :void
  (ResponseHandler-write! response status
                          '(("Content-Type" . "text/plain; charset=utf-8")
                            ("Cache-Control" . "no-store"))
                          (string->utf8 text)))

;; Every route keeps the loopback Host/Origin boundary, without a sign-in.
(def (handle-request (self : web-server) (request : Request) (response : ResponseHandler)) => :void
  (let (origin (header request "Origin"))
    (cond
     ((not (equal? (header request "Host") self.host))
      (respond-text response Forbidden "Unexpected Host."))
     ((and origin (not (string=? origin self.origin)))
      (respond-text response Forbidden "Unexpected Origin."))
     (else
      (route self request response (URL-path (Request-url request)))))))

(def (route (self : web-server) (request : Request) (response : ResponseHandler) (path : :string))
  => :void
  (let (method (Request-method request))
    (cond
     ((string=? path "/")
      (if (string=? method "GET")
        (ResponseHandler-write! response OK
                                '(("Content-Type" . "text/html; charset=utf-8")
                                  ("Cache-Control" . "no-store")
                                  ("Referrer-Policy" . "no-referrer"))
                                (new-page self))
        (respond-text response Method-Not-Allowed "Use GET.")))
     ((string=? path "/screen")
      (let (id (and (string=? method "GET")
                    (datastar-request? request)
                    (signals-tab-id (with-catch (lambda (e) #f) (lambda () (read-signals request))))))
        (if id
          (stream-screens self id request response)
          (respond-text response Bad-Request "Expected a Datastar GET from a tab."))))
     ((string=? path "/commands")
      (accept-event self request response))
     ((and (string=? path "/applied") (string=? method "POST"))
      (accept-applied self request response))
     ((and (string=? method "GET") (string-prefix? "/css/" path))
      (serve-css self request response path))
     ((and (string=? method "GET") (hash-get static-assets path))
      => (lambda ((asset : :pair))
           (ResponseHandler-write! response OK
                                   [(cons "Content-Type" (car asset))
                                    (cons "Cache-Control" "no-cache")]
                                   (:- (cdr asset) :u8vector))))
     (else
      (respond-text response Not-Found (string-append "Not found: " path))))))

;;; Tabs

;; A tab id: 1 to 64 letters, digits and hyphens (new-tab-id makes hex
;; digits); otherwise #f.
(def (parse-tab-id (value : :t)) => (Maybe :string)
  (and (string? value)
       (fx<= 1 (string-length value) 64)
       (andmap (lambda ((c : :char))
                 (or (char<=? #\a c #\z) (char<=? #\A c #\Z) (char<=? #\0 c #\9) (char=? c #\-)))
               (string->list value))
       value))

;; The tab id in SIGNALS, the signals a request carries, or #f.
(def (signals-tab-id (signals : :t)) => (Maybe :string)
  (and (hash-table? signals) (parse-tab-id (hash-get signals "tab"))))

;; The tab named ID, made the first time ID is seen, with no screen yet.
;; Unless new-page made it, its first item sets where its
;; numbering starts: a page whose tab was forgotten, or that was open
;; across a server restart, goes on counting. Call with SELF's mutex held.
(def (tab-named! (self : web-server) (id : :string)) => web-tab
  (or (hash-get self.tabs id)
      (let (tab (web-tab client: (make-client id)
                         next: 1 pending: (make-hash-table-eqv) numbered?: #f
                         rendered: empty-screen revision: 0
                         owed: #f wanted?: #f applied: (make-hash-table-eqv) streams: 0 closings: 0))
        (hash-put! self.tabs id tab)
        ;; A tab that never opens a stream is forgotten as if its streams
        ;; had closed.
        (forget-later! self tab)
        tab)))

;; Forget TAB SELF's grace period from now, unless one of its streams
;; opens meanwhile. Call with SELF's mutex held.
(def (forget-later! (self : web-server) (tab : web-tab)) => :void
  (unless self.stopped?
    (thread-send (:- self.keeper :thread) [tab tab.closings])))

;; Have the editor loop redisplay, so it renders the screens tabs want.
(def (ask-redisplay! (self : web-server)) => :void
  (thread-send (:- self.keeper :thread) 'redisplay))

;; Queues work for tabs on the editor loop, until sent 'stop: a redisplay
;; when sent 'redisplay (any task, even one doing nothing, is followed by
;; one), and forget-tab! for each [tab closings] from forget-later!, SELF's
;; grace period later, unless the tab is no longer one to forget, so a tab
;; with a stream open costs no task. It starts with the plugin, so it can
;; reach the editor loop, which request threads may not.
(def (tab-keeping-thread (self : web-server)) => :void
  (let lp ((waiting []))        ; [deadline tab closings] each, earliest first
    (let (wait (lambda (timeout)
                 (match (if timeout (thread-receive timeout #f) (thread-receive))
                   ('stop (void))
                   ('redisplay
                    (with-catch void (lambda () (spawn-task! 'tab-screen void)))
                    (lp waiting))
                   ([tab closings]
                    (lp (append waiting [[(+ (time->seconds (current-time)) self.grace) tab closings]])))
                   (else (lp waiting)))))
      (match waiting
        ([[deadline tab closings] . rest]
         (let (delay (- deadline (time->seconds (current-time))))
           (if (> delay 0)
             (wait delay)
             (begin
               (when (do-with-lock self.mutex (to-forget? self tab closings))
                 (with-catch void
                             (lambda ()
                               (spawn-task! 'forget-tab (lambda () (forget-tab! self tab closings))))))
               (lp rest)))))
        ([] (wait #f))))))

;; Whether TAB is still SELF's, and its streams last all closed when they
;; had closed CLOSINGS times, with none opened since. Call with SELF's
;; mutex held.
(def (to-forget? (self : web-server) (tab : web-tab) (closings : :fixnum)) => :boolean
  (and (eq? (hash-get self.tabs (client-id tab.client)) tab)
       (fxzero? tab.streams)
       (fx= tab.closings closings)))

;; On the editor loop: forget TAB if it is still one to forget (to-forget?);
;; then run client-gone-hook, so plugins forget what they kept for its
;; client.
(def (forget-tab! (self : web-server) (tab : web-tab) (closings : :fixnum)) => :void
  (when (do-with-lock self.mutex
          (and (to-forget? self tab closings)
               (begin (hash-remove! self.tabs (client-id tab.client)) #t)))
    (run-hook client-gone-hook tab.client)))

;; One writer per stream: send the tab named ID its newest screen once the
;; page applied the last one, preceded by the head whenever it differs from
;; the head this stream last sent, so a new stream gets the head first.
(def (stream-screens (self : web-server) (id : :string) (request : Request) (response : ResponseHandler))
  => :void
  (let* ((opened (do-with-lock self.mutex
                   (using (tab (tab-named! self id) : web-tab)
                     (set! tab.streams (fx1+ tab.streams))
                     ;; Its screen is rendered afresh, before it is sent.
                     (set! tab.wanted? #t)
                     (set! self.streams (fx1+ self.streams))
                     (cons tab self.streams))))
         (tab (:- (car opened) web-tab))
         (stream (:- (cdr opened) :fixnum)))
    (ask-redisplay! self)
    ;; A closed tab surfaces as a failed write; that ends this stream only.
    (with-catch
     void
     (lambda ()
       (call-with-datastar-sse request response
         (lambda (session)
           (let lp ((sent -1) (sent-head "") (count 0))
             (match (await-screen self tab stream sent count)
               ([revision head screen]
                (unless (string=? head sent-head)
                  (patch-elements session head))
                (let (stamps (screen-stamps revision stream (fx1+ count)))
                  (call-with-patch-elements
                   session
                   (lambda (out) (write-stamped-screen out screen stamps))))
                (lp revision head (fx1+ count)))
               ('heartbeat
                (patch-signals session "{}")
                (lp sent sent-head count))
               (else (void))))))))
    (using (tab : web-tab)
      (do-with-lock self.mutex
        (hash-remove! tab.applied stream)
        (set! tab.streams (fx1- tab.streams))
        (when (fxzero? tab.streams)
          (set! tab.closings (fx1+ tab.closings))
          (forget-later! self tab))))))

;; POST /applied?stream=S&count=N from a tab: its page applied stream S's
;; Nth screen.
(def (accept-applied (self : web-server) (request : Request) (response : ResponseHandler)) => :void
  ;; Read the signals Datastar posts before answering, as accept-event does.
  (let (id (signals-tab-id (with-catch (lambda (e) #f) (lambda () (read-signals request)))))
    (ResponseHandler-write! response No-Content [] #u8())
    (let* ((query (form-url-decode (or (URL-query (Request-url request)) "")))
           (number (lambda (name)
                     (let (pair (assoc name query))
                       (and pair (cdr pair) (string->number (cdr pair))))))
           (stream (number "stream"))
           (count (number "count")))
      (when (and id (fixnum? stream) (fixnum? count))
        (do-with-lock self.mutex
          (let (tab (hash-get self.tabs id))
            (when (and tab (fx> count (: (hash-ref (web-tab-applied tab) stream 0) :fixnum)))
              (hash-put! (web-tab-applied tab) stream count)
              (condition-variable-broadcast! self.changed))))))))

(def (json-content-type? (request : Request)) => :boolean
  (let (type (header request "Content-Type"))
    (and type
         (string-ci=? (string-trim-spaces (car (string-split type #\;)))
                      "application/json"))))

(def (accept-event (self : web-server) (request : Request) (response : ResponseHandler)) => :void
  (let* ((value (and (string=? (Request-method request) "POST")
                     (datastar-request? request)
                     (json-content-type? request)
                     (with-catch (lambda (e) #f) (lambda () (read-signals request)))))
         ;; Answer only once the body is read: the answer closes the
         ;; connection, and a body still on its way would be lost with it.
         ;; No command response carries feedback, even when its input is
         ;; rejected.
         (_ (ResponseHandler-write! response No-Content [] #u8()))
         (id (and (hash-table? value) (parse-tab-id (hash-get value "tab"))))
         ;; An item without a valid tab has no order to take its place in.
         (tab (and id (do-with-lock self.mutex (tab-named! self id))))
         (event (and tab
                     (with-catch (lambda (e) #f)
                                 (lambda ()
                                   (parse-input-item value (web-tab-client tab)
                                                     (do-with-lock self.mutex (web-tab-revision tab))))))))
    (when (and tab (paced-report? value))
      (if event
        (do-with-lock self.mutex (set! (web-tab-owed tab) #t))
        ;; No task runs for a rejected report, so answer it here.
        (resend-screen! self tab)))
    (cond
     (event
      (admit-event! self tab (hash-ref value "sequence") event))
     ;; A rejected item still takes its place in its tab's order, so the
     ;; items after it are not left waiting for it.
     ((and tab (fixnum? (hash-get value "sequence")) (fx>= (hash-get value "sequence") 1))
      (web-log.warnf "Dropped malformed %a input %a." (hash-get value "type") (hash-get value "sequence"))
      (admit-event! self tab (hash-get value "sequence") 'dropped))
     (else
      (web-log.warnf "Dropped malformed input.")))))

;; Whether VALUE, an input item, is one a page sends one at a time, waiting
;; for a screen before the next: a scroll report, or a pointer movement
;; while a button is held. Each is answered with a screen, even one that
;; changes nothing.
(def (paced-report? (value : HashTable)) => :boolean
  (let (type (hash-get value "type"))
    (or (equal? type "scroll")
        (and (equal? type "pointer") (equal? (hash-get value "kind") "movement")))))

;; HTTP handlers may arrive in any order. Submission stays under this lock
;; so another handler cannot overtake an item while it is handed to the loop.
;; EVENT, from TAB, is 'dropped for a rejected item, which is skipped in its
;; turn.
(def (admit-event! (self : web-server) (tab : web-tab) (sequence : :fixnum) (event : :t)) => :void
  (do-with-lock self.admission
    (unless tab.numbered?
      (set! tab.next sequence)
      (set! tab.numbered? #t))
    (cond
     ((or (fx< sequence tab.next) (hash-key? tab.pending sequence))
      (web-log.warnf "Ignored duplicate input %a." sequence))
     (else
      (hash-put! tab.pending sequence event)
      ;; A missing item that 64 later ones wait for is given up on, so
      ;; input carries on from the earliest item that did arrive.
      (when (fx> (hash-length tab.pending) 64)
        (web-log.warnf "Skipped missing input %a." tab.next)
        (set! tab.next (apply min (hash-keys tab.pending))))
      (let lp ()
        (let (next (hash-get tab.pending tab.next))
          (when next
            (hash-remove! tab.pending tab.next)
            (set! tab.next (fx1+ tab.next))
            (unless (eq? next 'dropped)
              ((web-server-submit self) next))
            (lp))))))))

(def (short-string? (value : :t)) => :boolean
  (and (string? value) (fx<= (string-length value) 64)))

;; A validated keydown event from the client FROM, or #f.
(def (parse-key-event (value : :t) (from : client-type)) => (Maybe key-event)
  (and (hash-table? value)
       (eqv? (hash-get value "version") 1)
       (equal? (hash-get value "type") "keydown")
       (let ((sequence (hash-get value "sequence"))
             (key (hash-get value "key"))
             (code (hash-get value "code"))
             (location (hash-get value "location"))
             (flags (map (lambda ((name : :string)) (hash-ref value name 'missing))
                         '("repeat" "isComposing" "altKey" "ctrlKey" "metaKey" "shiftKey"
                           "isMac" "altLeft" "altRight" "altGraph"))))
         (and (fixnum? sequence) (fx>= sequence 1)
              (short-string? key)
              (short-string? code)
              (fixnum? location) (fx<= 0 location 3)
              (andmap boolean? flags)
              (apply make-key-event sequence from key code location flags)))))

;; Browser buttons (0 left, 1 middle, 2 right) as Emacs numbers them.
(def browser-buttons '((0 . 1) (1 . 2) (2 . 3)))

;; A part name from data-part, "KIND:ID" ("tab-line:30", "status-line:12"), as
;; (kind . id), or #f.
(def (parse-part (value : :t)) => (Maybe :pair)
  (and (string? value)
       (fx<= (string-length value) 64)
       (let (colon (string-index value #\:))
         (and colon
              (let ((kind (substring value 0 colon))
                    (digits (substring value (fx1+ colon) (string-length value))))
                (and (fx<= 1 (string-length kind) 32)
                     (char-alphabetic? (string-ref kind 0))
                     (andmap (lambda ((c : :char)) (or (char<=? #\a c #\z) (char=? c #\-)))
                             (string->list kind))
                     (fx<= 1 (string-length digits) 15)
                     (andmap char-numeric? (string->list digits))
                     (cons (string->symbol kind) (string->number digits))))))))

;; The line of text a pointer item names, {item, charsRevision, column}
;; or null (missing: null): (VALID? ITEM CHARS-REVISION COLUMN), ITEM #f
;; for null.
(def (parse-line (value : :t)) => :list
  (cond
   ((void? value) [#t #f 0 0])
   ((hash-table? value)
    (let ((item (parse-token (hash-ref value "item" #f)))
          (revision (hash-get value "charsRevision"))
          (column (hash-get value "column")))
      (if (and (car item) (cdr item) (count? revision) (count? column))
        [#t (cdr item) revision column]
        [#f #f 0 0])))
   (else [#f #f 0 0])))

;; The kinds of pointer item, as the keys contract's pointer-event kinds.
(def pointer-kinds '(("click" . click) ("down" . down) ("movement" . movement) ("drag" . drag)))

;; A validated pointer item from the client FROM computed on a screen no newer than
;; NEWEST-REVISION, or #f.
(def (parse-pointer-event (value : :t) (from : client-type) (newest-revision : :fixnum))
  => (Maybe pointer-event)
  (and (hash-table? value)
       (eqv? (hash-get value "version") 1)
       (equal? (hash-get value "type") "pointer")
       (let ((kind (assoc (hash-get value "kind") pointer-kinds))
             (sequence (hash-get value "sequence"))
             (revision (hash-get value "revision"))
             (button (assv (hash-get value "button") browser-buttons))
             (clicks (hash-get value "clicks"))
             (modifiers (hash-get value "modifiers"))
             (part (parse-part (hash-get value "target")))
             (node (hash-ref value "node" (void)))
             (line (parse-line (hash-ref value "line" (void)))))
         (and kind
              (fixnum? sequence) (fx>= sequence 1)
              (fixnum? revision) (fx<= 0 revision newest-revision)
              button
              (fixnum? clicks) (fx<= 1 clicks 255)
              (hash-table? modifiers)
              part
              (or (void? node) (and (fixnum? node) (fx>= node 0)))
              (car line)
              (let (flags (map (lambda ((name : :string)) (hash-ref modifiers name 'missing))
                               '("alt" "ctrl" "meta" "shift")))
                (and (andmap boolean? flags)
                     (apply make-pointer-event sequence from (cdr kind) (cdr button) clicks
                            (append flags
                                    [(apply make-posn (car part) (cdr part)
                                            (and (fixnum? node) node) revision (cdr line))]))))))))

;; A pixel position or size no further than 10^9 px from 0, as a flonum,
;; or #f.
(def (parse-pixels (value : :t)) => (Maybe :flonum)
  (and (real? value) (<= -1e9 value 1e9) (exact->inexact value)))

(def (count? (value : :t)) => :boolean
  (and (fixnum? value) (fx>= value 0)))

;; An item token (the buffers contract's item-token: digits and dots), or
;; null for none: (VALID? . TOKEN), TOKEN #f for null.
(def (parse-token (value : :t)) => :pair
  (cond
   ((void? value) (cons #t #f))
   ((and (string? value)
         (fx<= 1 (string-length value) 64)
         (andmap (lambda ((c : :char)) (or (char-numeric? c) (char=? c #\.))) (string->list value)))
    (cons #t value))
   (else (cons #f #f))))

;; The posn of an item about view VIEW's scroller drawing from node NODE
;; on screen REVISION, no newer than NEWEST-REVISION, or #f.
(def (scroller-posn (value : HashTable) (newest-revision : :fixnum)) => (Maybe posn)
  (let ((revision (hash-get value "revision"))
        (view (hash-get value "view"))
        (node (hash-get value "node")))
    (and (fixnum? revision) (fx<= 0 revision newest-revision)
         (count? view) (count? node)
         (make-posn 'view view node revision #f 0 0))))

;; A pixel size: non-negative, as parse-pixels takes it, or #f.
(def (parse-size (value : :t)) => (Maybe :flonum)
  (let (px (parse-pixels value))
    (and px (fl>= px 0.) px)))

;; The spacers a scroll item may name its top edge in.
(def spacer-sides '(("above" . above) ("below" . below)))

;; A validated scroll item from the client FROM computed on a screen no newer than
;; NEWEST-REVISION, or #f. TOP, LASTVISIBLE and SPACER are null when
;; nothing is there, but never missing; a SPACER names the drawn item next
;; to it as TOP.
(def (parse-scroll-event (value : :t) (from : client-type) (newest-revision : :fixnum))
  => (Maybe scroll-event)
  (and (hash-table? value)
       (eqv? (hash-get value "version") 1)
       (equal? (hash-get value "type") "scroll")
       (hash-key? value "top")
       (hash-key? value "lastVisible")
       (hash-key? value "spacer")
       (let ((sequence (hash-get value "sequence"))
             (start (scroller-posn value newest-revision))
             (placement (hash-get value "placement"))
             (top (parse-token (hash-get value "top")))
             (offset (parse-pixels (hash-get value "offset")))
             (last-visible (parse-token (hash-get value "lastVisible")))
             (spacer (let (side (hash-get value "spacer"))
                       (if (void? side) (cons #t #f) (let (known (assoc side spacer-sides))
                                                       (if known (cons #t (cdr known)) (cons #f #f))))))
             (spacer-distance (parse-size (hash-get value "spacerDistance")))
             (before (hash-get value "before"))
             (after (hash-get value "after"))
             (drawn-height (parse-size (hash-get value "drawnHeight")))
             (above (parse-size (hash-get value "above")))
             (below (parse-size (hash-get value "below")))
             (width (hash-get value "width"))
             (height (hash-get value "height"))
             (settled (hash-get value "settled")))
         (and (fixnum? sequence) (fx>= sequence 1)
              start
              (count? placement)
              (car top) offset (car last-visible)
              (car spacer) (or (not (cdr spacer)) (cdr top)) spacer-distance
              (count? before) (count? after)
              drawn-height above below
              (fixnum? width) (fx<= 0 width 1000000)
              (fixnum? height) (fx<= 0 height 1000000)
              (boolean? settled)
              (make-scroll-event sequence from start placement (cdr top) offset (cdr last-visible)
                                 (cdr spacer) spacer-distance before after drawn-height
                                 above below width height settled)))))

;; A validated keydown, pointer or scroll item from the client FROM, or #f.
(def (parse-input-item (value : :t) (from : client-type) (newest-revision : :fixnum)) => :t
  (and (hash-table? value)
       (let (type (hash-get value "type"))
         (cond
          ((equal? type "keydown") (parse-key-event value from))
          ((equal? type "pointer") (parse-pointer-event value from newest-revision))
          ((equal? type "scroll") (parse-scroll-event value from newest-revision))
          (else #f)))))

;;; The plugin

(def (stop-web-transport! (self : web-server)) => :void
  (do-with-lock self.mutex
    (set! self.stopped? #t)
    (condition-variable-broadcast! self.changed))
  (thread-send (:- self.keeper :thread) 'stop)
  (Server-stop! (Server self.server)))

(defplugin (web-transport ctx)
  "Serves screens to browser tabs on loopback and receives their input."
  provides: [display-service]
  optional: [renderer-service]
  (add-stylesheet 'tokens "tokens.css")
  (add-stylesheet 'rules "rules.css")
  (let* ((port (let (configured (plugin-option web-transport 'port))
                 (if (zero? configured) (free-loopback-port) configured)))
         (host (string-append "127.0.0.1:" (number->string port)))
         (self (web-server submit: (input-submitter)
                              port: port
                              host: host
                              origin: (string-append "http://" host)
                              admission: (make-mutex 'tuna-admission)
                              slot-numbers: (make-hash-table)
                              ;; The first redisplay reads the registry.
                              stylesheets-seen: -1
                              grace: (/ (plugin-option web-transport 'tab-grace) 1000.)
                              keeper: #f
                              mutex: (make-mutex 'tuna-screen)
                              changed: (make-condition-variable 'tuna-screen)
                              tabs: (make-hash-table)
                              head: (render-head [])
                              served: []
                              revision: 0
                              stopped?: #f
                              streams: 0
                              timeout: (/ (plugin-option web-transport 'screen-timeout) 1000.)
                              server: #f))
         (server (new-http-server
                  (ServerConfig
                   mux: (new-static-mux
                         rest: "" (new-closure-handler
                                   (lambda (request response)
                                     (handle-request self request response))))
                   log: (stderr-log-sink)
                   listen: [(string-append "inet4:" host)]
                   response-timeout: !NoTimeout))))
    (set! (web-server-server self) server)
    (set! (web-server-keeper self) (spawn-thread (lambda () (tab-keeping-thread self)) 'tuna-tabs))
    (Server-start! server)
    (context-defer! ctx (lambda () (stop-web-transport! self)))
    (context-provide! ctx display-service self)
    (web-log.infof "Tuna %a is running. Open http://%a/"
                   (tuna-version) host)))

(defplugin-options web-transport
  (port 0 "The loopback port to listen on; 0 picks a free one."
        (integer-type 0 65535) flag: "--port")
  (screen-timeout 1000 "Milliseconds a page may take to confirm a screen before the newest is sent again."
                  (integer-type 1 60000))
  (tab-grace 60000
             "Milliseconds a tab whose screen streams have all closed is kept; a stream reopening in time keeps its place."
             (integer-type 1 86400000)))
