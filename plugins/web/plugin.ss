#lang :tuna/prelude
;;; Web transport (startup tier): the loopback HTTP server, the page shell,
;;; ordered input over POST /commands, and the screen stream (ADR 7, ADR 10).
;;;
;;; POST /commands takes one input item: a keydown or a pointer item, each
;;; with its page-load sequence number, validated strictly into a
;;; key-event or a pointer-event. Each screen carries its revision as
;;; data-revision on its root element, and a pointer item names the screen
;;; it was computed on, which must be one this transport sent.

(import (only-in :gerbil/runtime/hash HashTable)
        :std/io
        :std/log
        :std/net/address
        :std/net/http/server
        :std/net/url
        :std/text/markup/sxml/print
        :std/time/timeout
        :gerbil-datastar/http
        :tuna/kernel
        :tuna/version
        :tuna/lib/plugin-options
        (only-in :tuna/plugins/keys/contract key-event make-key-event pointer-event make-pointer-event make-posn)
        :tuna/plugins/renderer/contract
        :tuna/plugins/web/embed)
(export web-transport
        web-transport-url)

(deflogger web-log name: "tuna/web")

;; Seconds between keep-alive events, which also detect closed tabs.
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
   (mutex       : :mutex)       ; guards the fields below
   (changed     : :condvar)
   (screen      : :string)      ; the newest screen
   (revision    : :fixnum)
   (stopped?    : :boolean)
   (server      : :t))
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
  (let* ((size (string-length screen))
         (end (let lp ((i 1))
                (if (and (fx< i size)
                         (not (memv (string-ref screen i) '(#\space #\tab #\newline #\> #\/))))
                  (lp (fx1+ i))
                  i))))
    (if (and (fx> size 1) (char=? (string-ref screen 0) #\<))
      (string-append (substring screen 0 end)
                     " data-revision=\"" (number->string revision) "\""
                     (substring screen end size))
      screen)))

;; Only the editor loop redisplays, so revisions are assigned in order.
(defmethod {redisplay! web-server}
  (lambda (self)
    (using (self : web-server)
      (let* ((revision (fx1+ (do-with-lock self.mutex self.revision)))
             (screen (stamp-revision (render-screen) revision)))
        (do-with-lock self.mutex
          (set! self.screen screen)
          (set! self.revision revision)
          (condition-variable-broadcast! self.changed))))))

;; The newest screen as (revision . html) once it is newer than SENT;
;; 'heartbeat after TIMEOUT seconds; #f once stopped. Never touches editor
;; state, so a slow client never holds up the editor loop.
(def (await-screen (self : web-server) (sent : :fixnum) (timeout : :real)) => :t
  (let (deadline (+ (time->seconds (current-time)) timeout))
    (mutex-lock! self.mutex)
    (let lp ()
      (cond
       (self.stopped?
        (mutex-unlock! self.mutex)
        #f)
       ((fx> self.revision sent)
        (let (newest (cons self.revision self.screen))
          (mutex-unlock! self.mutex)
          newest))
       ((mutex-unlock! self.mutex self.changed
                       (max 0. (- deadline (time->seconds (current-time)))))
        (mutex-lock! self.mutex)
        (lp))
       (else 'heartbeat)))))

(def (current-screen (self : web-server)) => :string
  (:- (do-with-lock self.mutex self.screen) :string))

(def (html-string (markup : :list)) => :string
  (call-with-output-string ""
    (lambda (port) (write-sxml markup port: port xml?: #f))))

(def (page-html (screen : :string)) => :string
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
   (html-string
    '(head
      (meta (@ (charset "utf-8")))
      (meta (@ (name "viewport") (content "width=device-width, initial-scale=1")))
      (title "Tuna")
      (link (@ (rel "stylesheet") (href "/static/tuna.css")))
      (script (@ (type "importmap"))
              "{\"imports\":{\"datastar\":\"/static/datastar-v1.0.2.js\"}}")
      (script (@ (type "module") (src "/static/tuna-input.js")))))
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
                                (string->utf8 (page-html (current-screen self)))))
        (respond-text response Method-Not-Allowed "Use GET.")))
     ((string=? path "/screen")
      (if (and (string=? method "GET") (datastar-request? request))
        (stream-screens self request response)
        (respond-text response Bad-Request "Expected a Datastar GET.")))
     ((string=? path "/commands")
      (accept-event self request response))
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

;; One writer per client: send the newest screen whenever it changes.
(def (stream-screens (self : web-server) (request : Request) (response : ResponseHandler)) => :void
  ;; A closed tab surfaces as a failed write; that ends this stream only.
  (with-catch
   void
   (lambda ()
     (call-with-datastar-sse request response
       (lambda (session)
         (let lp ((sent -1))
           (let (next (await-screen self sent heartbeat-seconds))
             (cond
              ((pair? next)
               (patch-elements session (cdr next))
               (lp (car next)))
              ((eq? next 'heartbeat)
               (patch-signals session "{}")
               (lp sent))))))))))

(def (json-content-type? (request : Request)) => :boolean
  (let (type (header request "Content-Type"))
    (and type
         (string-ci=? (string-trim-spaces (car (string-split type #\;)))
                      "application/json"))))

(def (accept-event (self : web-server) (request : Request) (response : ResponseHandler)) => :void
  ;; No command response carries feedback, even when its input is rejected.
  (ResponseHandler-write! response No-Content [] #u8())
  (let* ((value (and (string=? (Request-method request) "POST")
                     (datastar-request? request)
                     (json-content-type? request)
                     (with-catch (lambda (e) #f) (lambda () (read-signals request)))))
         (event (with-catch (lambda (e) #f)
                            (lambda ()
                              (parse-input-item value (do-with-lock self.mutex self.revision))))))
    (if event
      (admit-event! self (hash-ref value "sequence") event)
      (web-log.warnf "Dropped malformed input."))))

;; HTTP handlers may arrive in any order. Submission stays under this lock
;; so another handler cannot overtake an item while it is handed to the loop.
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
            ((web-server-submit self) next)
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

;; A validated keydown or pointer item, or #f.
(def (parse-input-item (value : :t) (newest-revision : :fixnum)) => :t
  (and (hash-table? value)
       (let (type (hash-get value "type"))
         (cond
          ((equal? type "keydown") (parse-key-event value))
          ((equal? type "pointer") (parse-pointer-event value newest-revision))
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
                              mutex: (make-mutex 'tuna-screen)
                              changed: (make-condition-variable 'tuna-screen)
                              screen: (stamp-revision "<main id=\"screen\"></main>" 0)
                              revision: 0
                              stopped?: #f
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
        (integer-type 0 65535) flag: "--port"))
