#lang :tuna/prelude
;;; Web transport (startup tier): the loopback HTTP server, the page shell,
;;; ordered input over POST /commands, and the screen stream (ADR 7, ADR 10).
;;;
;;; POST /commands takes one input item: a keydown, a pointer or a scroll
;;; item, each with its page-load sequence number, validated strictly into
;;; a key-event, a pointer-event or a scroll-event. Each screen carries its
;;; revision as data-revision on its root element, and pointer and scroll
;;; items name the screen they were computed on, which must be one this
;;; transport sent. The page's actions (frontend/) measure and report
;;; scrolling (tunaScroll) and place a view where the server asks
;;; (tunaPlace).
;;;
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
        :std/io
        :std/log
        :std/misc/ports
        :std/net/address
        :std/net/http/server
        :std/net/mime/file
        :std/net/uri
        :std/net/url
        :std/text/markup/sxml/print
        :std/time/timeout
        :gerbil-datastar/http
        :tuna/kernel
        :tuna/version
        :tuna/lib/plugin-options
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
   (admission   : :mutex)       ; guards input ordering and submission
   (next        : :fixnum)      ; next page-load sequence to submit
   (pending     : HashTable)  ; sequence -> input item
   (numbered?   : :boolean)     ; whether a page load or first item set NEXT
   (slot-numbers : HashTable)   ; (owner . name) -> n in /css/<n>/; editor thread only
   (stylesheets-seen : :fixnum) ; the stylesheets generation HEAD shows; editor thread only
   (mutex       : :mutex)       ; guards the fields below
   (changed     : :condvar)
   (head        : :string)      ; the newest <head>
   (served      : :list)        ; the served-stylesheets HEAD links
   (screen      : :string)      ; the newest screen
   (rendered    : :string)      ; the renderer's output for it, before stamping
   (owed        : :boolean)     ; a scroll report awaits a screen
   (revision    : :fixnum)
   (stopped?    : :boolean)
   (streams     : :fixnum)      ; streams opened so far, to number them
   (applied     : HashTable)    ; stream -> last screen count its page applied
   (timeout     : :real)        ; seconds a page may take to confirm a screen
   (server      : :t))
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

(def (render-screen) => :string
  (let (renderer (service-provider renderer-service))
    (if renderer
      (:- (Renderer-render-screen (Renderer renderer)) :string)
      "<main id=\"screen\"><p>No renderer is active.</p></main>")))

;; SCREEN with REVISION as data-revision on its root element, so that
;; pointer items can name the screen they were computed on (ADR 7).
(def (stamp-revision (screen : :string) (revision : :fixnum)) => :string
  (add-root-attributes screen (string-append " data-revision=\"" (number->string revision) "\"")))

;; SCREEN, as the COUNTth screen sent on STREAM, telling the page to
;; confirm it once applied (go-latest-frame-spike's /next).
(def (stamp-applied (screen : :string) (stream : :fixnum) (count : :fixnum)) => :string
  (add-root-attributes
   screen
   (string-append " data-init=\"@post('/applied?stream=" (number->string stream)
                  "&amp;count=" (number->string count) "'); el.removeAttribute('data-init')\"")))

;; SCREEN with ATTRIBUTES (text with a leading space) after its root tag name.
(def (add-root-attributes (screen : :string) (attributes : :string)) => :string
  (let* ((size (string-length screen))
         (end (let lp ((i 1))
                (if (and (fx< i size)
                         (not (memv (string-ref screen i) '(#\space #\tab #\newline #\> #\/))))
                  (lp (fx1+ i))
                  i))))
    (if (and (fx> size 1) (char=? (string-ref screen 0) #\<))
      (string-append (substring screen 0 end) attributes (substring screen end size))
      screen)))

;; Only the editor loop redisplays, so revisions are assigned in order.
;; It also holds the baton, so it may read the stylesheets registry.
(defmethod {redisplay! web-server}
  (lambda (self)
    (using (self : web-server)
      (let* ((served (changed-stylesheets self))
             (rendered (render-screen)))
        ;; A screen is drawn only from editor state, so the same screen as
        ;; the last one means nothing on it changed: it gets no new revision
        ;; and nothing is sent. Timers such as the session save redisplay
        ;; without changing what is shown.
        ;; A page sends one scroll report at a time and waits for a screen
        ;; before the next, so a report is always answered with one.
        (unless (and (not served)
                     (do-with-lock self.mutex
                       (and (not self.owed) (string=? rendered self.rendered))))
          (publish-screen! self rendered (and served (render-head served)) served))))))

;; Send RENDERED (and HEAD for SERVED stylesheets, when given) as the next
;; screen revision.
(def (publish-screen! (self : web-server) (rendered : :string) (head : :t) (served : :t)) => :void
  (do-with-lock self.mutex
    (let (revision (fx1+ self.revision))
      (when served
        (set! self.head head)
        (set! self.served served))
      (set! self.screen (stamp-revision rendered revision))
      (set! self.rendered rendered)
      (set! self.revision revision)
      (set! self.owed #f)
      (condition-variable-broadcast! self.changed))))

;; The newest screen as [revision head screen] once STREAM's page has
;; applied its COUNTth screen and one newer than SENT exists; the newest
;; again when the page has not confirmed within SELF's timeout; 'heartbeat
;; after heartbeat-seconds of nothing to send; #f once stopped. Never
;; touches editor state, so a slow client never holds up the editor loop.
(def (await-screen (self : web-server) (stream : :fixnum) (sent : :fixnum) (count : :fixnum)) => :t
  (let (start (time->seconds (current-time)))
    (mutex-lock! self.mutex)
    (let lp ()
      (let* ((applied? (fx>= (: (hash-ref self.applied stream 0) :fixnum) count))
             (deadline (+ start (if applied? heartbeat-seconds self.timeout)))
             (newest (lambda () (let (newest [self.revision self.head self.screen])
                                  (mutex-unlock! self.mutex)
                                  newest))))
        (cond
         (self.stopped?
          (mutex-unlock! self.mutex)
          #f)
         ((and applied? (fx> self.revision sent))
          (newest))
         ((>= (time->seconds (current-time)) deadline)
          (if applied?
            (begin (mutex-unlock! self.mutex) 'heartbeat)
            (newest)))
         (else
          (mutex-unlock! self.mutex self.changed (max 0. (- deadline (time->seconds (current-time)))))
          (mutex-lock! self.mutex)
          (lp)))))))

(def (current-page (self : web-server)) => :string
  (do-with-lock self.mutex
    (page-html self.head self.screen)))

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

(def (page-html (head : :string) (screen : :string)) => :string
  (string-append
   "<!doctype html>"
   "<html lang=\"en\" data-init=\"@get('/screen')\""
   " data-on:keydown__document__capture=\"@tunaKeyboard()\""
   ;; One pointer action for clicks on release (click, auxclick), and for
   ;; presses on chrome that must not move focus (mousedown, contextmenu).
   " data-on:mousedown__document=\"@tunaPointer()\""
   " data-on:contextmenu__document=\"@tunaPointer()\""
   " data-on:click__document=\"@tunaPointer()\""
   " data-on:auxclick__document=\"@tunaPointer()\">"
   head
   ;; The renderer's HTML is already escaped.
   "<body>" screen "</body></html>"))

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
        (begin
         (restart-numbering! self)
         (ResponseHandler-write! response OK
                                '(("Content-Type" . "text/html; charset=utf-8")
                                  ("Cache-Control" . "no-store")
                                  ("Referrer-Policy" . "no-referrer"))
                                (string->utf8 (current-page self))))
        (respond-text response Method-Not-Allowed "Use GET.")))
     ((string=? path "/screen")
      (if (and (string=? method "GET") (datastar-request? request))
        (stream-screens self request response)
        (respond-text response Bad-Request "Expected a Datastar GET.")))
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

;; A page numbers its input from 1 when it loads, so serving the page starts
;; numbering again. A stream that reconnects without a reload keeps it: the
;; page's count goes on. One tab only.
(def (restart-numbering! (self : web-server)) => :void
  (do-with-lock self.admission
    (set! self.next 1)
    (set! self.numbered? #t)
    (hash-clear! self.pending)))

;; One writer per client: send the newest screen once the page applied the
;; last one, preceded by the head whenever it differs from the head this
;; stream last sent, so a new stream gets the head first.
(def (stream-screens (self : web-server) (request : Request) (response : ResponseHandler)) => :void
  (let (stream (do-with-lock self.mutex
                 (set! self.streams (fx1+ self.streams))
                 self.streams))
    ;; A closed tab surfaces as a failed write; that ends this stream only.
    (with-catch
     void
     (lambda ()
       (call-with-datastar-sse request response
         (lambda (session)
           (let lp ((sent -1) (sent-head "") (count 0))
             (match (await-screen self stream sent count)
               ([revision head screen]
                (unless (string=? head sent-head)
                  (patch-elements session head))
                (patch-elements session (stamp-applied screen stream (fx1+ count)))
                (lp revision head (fx1+ count)))
               ('heartbeat
                (patch-signals session "{}")
                (lp sent sent-head count))
               (else (void))))))))
    (do-with-lock self.mutex (hash-remove! self.applied stream))))

;; POST /applied?stream=S&count=N: the page applied stream S's Nth screen.
(def (accept-applied (self : web-server) (request : Request) (response : ResponseHandler)) => :void
  ;; Read the signals Datastar posts before answering, as accept-event does.
  (with-catch void (lambda () (read-signals request)))
  (ResponseHandler-write! response No-Content [] #u8())
  (let* ((query (form-url-decode (or (URL-query (Request-url request)) "")))
         (number (lambda (name)
                   (let (pair (assoc name query))
                     (and pair (cdr pair) (string->number (cdr pair))))))
         (stream (number "stream"))
         (count (number "count")))
    (when (and (fixnum? stream) (fixnum? count))
      (do-with-lock self.mutex
        (when (fx> count (: (hash-ref self.applied stream 0) :fixnum))
          (hash-put! self.applied stream count)
          (condition-variable-broadcast! self.changed))))))

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
         (event (with-catch (lambda (e) #f)
                            (lambda ()
                              (parse-input-item value (do-with-lock self.mutex self.revision))))))
    (when (and (hash-table? value) (equal? (hash-get value "type") "scroll"))
      (if event
        (do-with-lock self.mutex (set! self.owed #t))
        ;; No task runs for a rejected report, so answer it here.
        (let (rendered (do-with-lock self.mutex self.rendered))
          (unless (fxzero? (string-length rendered))
            (publish-screen! self rendered #f #f)))))
    (cond
     (event
      (admit-event! self (hash-ref value "sequence") event))
     ;; A rejected item still takes its place in the order, so the items
     ;; after it are not left waiting for it.
     ((and (hash-table? value) (fixnum? (hash-get value "sequence")) (fx>= (hash-get value "sequence") 1))
      (web-log.warnf "Dropped malformed %a input %a." (hash-get value "type") (hash-get value "sequence"))
      (admit-event! self (hash-get value "sequence") 'dropped))
     (else
      (web-log.warnf "Dropped malformed input.")))))

;; HTTP handlers may arrive in any order. Submission stays under this lock
;; so another handler cannot overtake an item while it is handed to the loop.
;; EVENT is 'dropped for a rejected item, which is skipped in its turn.
(def (admit-event! (self : web-server) (sequence : :fixnum) (event : :t)) => :void
  (do-with-lock self.admission
    ;; After a server restart the open page keeps its count and loads no new
    ;; page, so the first item seen sets the numbering.
    (unless self.numbered?
      (set! self.next sequence)
      (set! self.numbered? #t))
    (cond
     ((or (fx< sequence self.next) (hash-key? self.pending sequence))
      (web-log.warnf "Ignored duplicate input %a." sequence))
     (else
      (hash-put! self.pending sequence event)
      ;; A missing item that 64 later ones wait for is given up on, so
      ;; input carries on from the earliest item that did arrive.
      (when (fx> (hash-length self.pending) 64)
        (web-log.warnf "Skipped missing input %a." self.next)
        (set! self.next (apply min (hash-keys self.pending))))
      (let lp ()
        (let (next (hash-get self.pending self.next))
          (when next
            (hash-remove! self.pending self.next)
            (set! self.next (fx1+ self.next))
            (unless (eq? next 'dropped)
              ((web-server-submit self) next))
            (lp))))))))

(def (short-string? (value : :t)) => :boolean
  (and (string? value) (fx<= (string-length value) 64)))

;; A validated keydown event, or #f.
(def (parse-key-event (value : :t)) => (Maybe key-event)
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
              (apply make-key-event sequence key code location flags)))))

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

;; A validated pointer item computed on a screen no newer than
;; NEWEST-REVISION, or #f.
(def (parse-pointer-event (value : :t) (newest-revision : :fixnum)) => (Maybe pointer-event)
  (and (hash-table? value)
       (eqv? (hash-get value "version") 1)
       (equal? (hash-get value "type") "pointer")
       (equal? (hash-get value "kind") "click")
       (let ((sequence (hash-get value "sequence"))
             (revision (hash-get value "revision"))
             (button (assv (hash-get value "button") browser-buttons))
             (clicks (hash-get value "clicks"))
             (modifiers (hash-get value "modifiers"))
             (part (parse-part (hash-get value "target")))
             (node (hash-ref value "node" (void))))
         (and (fixnum? sequence) (fx>= sequence 1)
              (fixnum? revision) (fx<= 0 revision newest-revision)
              button
              (fixnum? clicks) (fx<= 1 clicks 255)
              (hash-table? modifiers)
              part
              (or (void? node) (and (fixnum? node) (fx>= node 0)))
              (let (flags (map (lambda ((name : :string)) (hash-ref modifiers name 'missing))
                               '("alt" "ctrl" "meta" "shift")))
                (and (andmap boolean? flags)
                     (apply make-pointer-event sequence (cdr button) clicks
                            (append flags
                                    [(make-posn (car part) (cdr part)
                                                (and (fixnum? node) node) revision)]))))))))

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
         (make-posn 'view view node revision))))

;; A pixel size: non-negative, as parse-pixels takes it, or #f.
(def (parse-size (value : :t)) => (Maybe :flonum)
  (let (px (parse-pixels value))
    (and px (fl>= px 0.) px)))

;; The spacers a scroll item may name its top edge in.
(def spacer-sides '(("above" . above) ("below" . below)))

;; A validated scroll item computed on a screen no newer than
;; NEWEST-REVISION, or #f. TOP, LASTVISIBLE and SPACER are null when
;; nothing is there, but never missing; a SPACER names the drawn item next
;; to it as TOP.
(def (parse-scroll-event (value : :t) (newest-revision : :fixnum)) => (Maybe scroll-event)
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
             (height (hash-get value "height")))
         (and (fixnum? sequence) (fx>= sequence 1)
              start
              (count? placement)
              (car top) offset (car last-visible)
              (car spacer) (or (not (cdr spacer)) (cdr top)) spacer-distance
              (count? before) (count? after)
              drawn-height above below
              (fixnum? width) (fx<= 0 width 1000000)
              (fixnum? height) (fx<= 0 height 1000000)
              (make-scroll-event sequence start placement (cdr top) offset (cdr last-visible)
                                 (cdr spacer) spacer-distance before after drawn-height
                                 above below width height)))))

;; A validated keydown, pointer or scroll item, or #f.
(def (parse-input-item (value : :t) (newest-revision : :fixnum)) => :t
  (and (hash-table? value)
       (let (type (hash-get value "type"))
         (cond
          ((equal? type "keydown") (parse-key-event value))
          ((equal? type "pointer") (parse-pointer-event value newest-revision))
          ((equal? type "scroll") (parse-scroll-event value newest-revision))
          (else #f)))))

;;; The plugin

(def (stop-web-transport! (self : web-server)) => :void
  (do-with-lock self.mutex
    (set! self.stopped? #t)
    (condition-variable-broadcast! self.changed))
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
                              next: 1
                              pending: (make-hash-table-eqv)
                              numbered?: #f
                              slot-numbers: (make-hash-table)
                              ;; The first redisplay reads the registry.
                              stylesheets-seen: -1
                              mutex: (make-mutex 'tuna-screen)
                              changed: (make-condition-variable 'tuna-screen)
                              head: (render-head [])
                              served: []
                              screen: (stamp-revision "<main id=\"screen\"></main>" 0)
                              rendered: ""
                              owed: #f
                              revision: 0
                              stopped?: #f
                              streams: 0
                              applied: (make-hash-table-eqv)
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
    (Server-start! server)
    (context-defer! ctx (lambda () (stop-web-transport! self)))
    (context-provide! ctx display-service self)
    (web-log.infof "Tuna %a is running. Open http://%a/"
                   (tuna-version) host)))

(defplugin-options web-transport
  (port 0 "The loopback port to listen on; 0 picks a free one."
        (integer-type 0 65535) flag: "--port")
  (screen-timeout 1000 "Milliseconds a page may take to confirm a screen before the newest is sent again."
                  (integer-type 1 60000)))
