;;; Web transport (startup tier): the loopback HTTP server, client
;;; authentication, the page shell, POST /commands, and one SSE stream per
;;; client (ADR 7, ADR 10).
prelude: :gerbil/core

(import :std/crypto/random
        :std/encoding/hex
        :std/io
        :std/log
        :std/net/address
        :std/net/http/server
        :std/net/url
        :std/text/markup/sxml/print
        :std/time/timeout
        :gerbil-datastar/http
        :tuna/kernel
        :tuna/services/renderer
        ./web/embed)
(export web-transport-plugin
        web-transport-listen-port
        web-transport-url)

;; The loopback port to listen on; 0 picks a free one.
(def web-transport-listen-port (make-parameter 0))

;; Seconds between keep-alive events, which also detect closed tabs.
(def heartbeat-seconds 15.)

(def static-assets (embed-directory "../../web" "/static"))

(defclass web-transport
  ((editor      : kernel)       ; the kernel whose loop receives input
   (port        : :fixnum)
   (token       : :string)      ; in the launch URL
   (session     : :string)      ; the cookie it is exchanged for
   (cookie-name : :string)
   (host        : :string)      ; the only Host accepted
   (origin      : :string)      ; the only Origin accepted
   (admission   : :mutex)       ; orders acknowledgement and enqueueing
   (mutex       : :mutex)       ; guards the fields below
   (changed     : :condvar)
   (screen      : :string)      ; the newest screen
   (revision    : :fixnum)
   (stopped?    : :boolean)
   (server      : :t))
  final: #t)

(def (new-secret) => :string
  (hex-encode (random-bytes 32)))

;; Bind and release an ephemeral loopback port.
(def (free-loopback-port) => :fixnum
  (using (socket (tcp-listen (string->address "inet4:127.0.0.1:0")) : ServerSocket)
    (let (address (socket.address))
      (socket.close)
      (:- (InetAddress-port address) :fixnum))))

;; The launch URL, carrying the token, of the active web transport.
(def (web-transport-url) => (Maybe :string)
  (let (display (service-provider display-service))
    (and (web-transport? display)
         (using (self display : web-transport)
           (string-append "http://" self.host "/?token=" self.token)))))

;;; Screens

(def (render-screen) => :string
  (let (renderer (service-provider renderer-service))
    (if renderer
      (Renderer-render-screen (Renderer renderer))
      "<main id=\"screen\"><p>No renderer is active.</p></main>")))

(defmethod {redisplay! web-transport}
  (lambda (self)
    (using (self : web-transport)
      (let (screen (render-screen))
        (do-with-lock self.mutex
          (set! self.screen screen)
          (set! self.revision (fx1+ self.revision))
          (condition-variable-broadcast! self.changed))))))

;; The newest screen as (revision . html) once it is newer than SENT;
;; 'heartbeat after TIMEOUT seconds; #f once stopped. Never touches editor
;; state, so a slow client never holds up the editor loop.
(def (await-screen (self : web-transport) (sent : :fixnum) (timeout : :real)) => :t
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

(def (current-screen (self : web-transport)) => :string
  (:- (do-with-lock self.mutex self.screen) :string))

(def (html-string (markup : :list)) => :string
  (call-with-output-string ""
    (lambda (port) (write-sxml markup port: port xml?: #f))))

(def (page-html (screen : :string)) => :string
  (string-append
   "<!doctype html>"
   "<html lang=\"en\" data-init=\"@get('/screen')\""
   " data-on:keydown__document__capture=\"@tunaKeyboard()\">"
   (html-string
    '(head
      (meta (@ (charset "utf-8")))
      (meta (@ (name "viewport") (content "width=device-width, initial-scale=1")))
      (title "Tuna")
      (link (@ (rel "stylesheet") (href "/static/tuna.css")))
      (script (@ (type "importmap"))
              "{\"imports\":{\"datastar\":\"/static/datastar-v1.0.2.js\"}}")
      (script (@ (type "module") (src "/static/tuna-keyboard.js")))))
   ;; The renderer's HTML is already escaped.
   "<body>" screen "</body></html>"))

;;; Requests

(def (header (request : Request) (name : :string)) => (Maybe :string)
  (let lp ((rest (Request-headers request)))
    (match rest
      ([[key . value] . more]
       (if (string-ci=? key name) value (lp more)))
      (else #f))))

(def (cookie (request : Request) (name : :string)) => (Maybe :string)
  (let (cookies (header request "Cookie"))
    (and cookies
         (let lp ((parts (string-split cookies #\;)))
           (match parts
             ([part . more]
              (let* ((part (string-trim-spaces part))
                     (equals (string-index part #\=)))
                (if (and equals (string=? (substring part 0 equals) name))
                  (substring part (fx1+ equals) (string-length part))
                  (lp more))))
             (else #f))))))

(def (string-trim-spaces (text : :string)) => :string
  (let* ((end (string-length text))
         (start (let lp ((i 0)) (if (and (fx< i end) (char=? (string-ref text i) #\space)) (lp (fx1+ i)) i)))
         (stop (let lp ((i end)) (if (and (fx> i start) (char=? (string-ref text (fx1- i)) #\space)) (lp (fx1- i)) i))))
    (substring text start stop)))

(def (query-token (request : Request)) => (Maybe :string)
  (let (query (URL-query (Request-url request)))
    (and query
         (let lp ((parts (string-split query #\&)))
           (match parts
             ([part . more]
              (if (string-prefix? "token=" part)
                (substring part 6 (string-length part))
                (lp more)))
             (else #f))))))

;; Compare secrets in time independent of where they differ.
(def (secret=? (given : :string) (expected : :string)) => :boolean
  (and (fx= (string-length given) (string-length expected))
       (let lp ((i 0) (difference 0))
         (if (fx< i (string-length given))
           (lp (fx1+ i)
               (fxior difference
                      (fxxor (char->integer (string-ref given i))
                             (char->integer (string-ref expected i)))))
           (fxzero? difference)))))

(def (respond-text (response : ResponseHandler) (status : Status) (text : :string)) => :void
  (ResponseHandler-write! response status
                          '(("Content-Type" . "text/plain; charset=utf-8")
                            ("Cache-Control" . "no-store"))
                          (string->utf8 text)))

;; Every request: Host and Origin first, then the launch token or the
;; session cookie (ADR 10).
(def (handle-request (self : web-transport) (request : Request) (response : ResponseHandler)) => :void
  (let ((path (URL-path (Request-url request)))
        (origin (header request "Origin"))
        (token (query-token request)))
    (cond
     ((not (equal? (header request "Host") self.host))
      (respond-text response Forbidden "Unexpected Host."))
     ((and origin (not (string=? origin self.origin)))
      (respond-text response Forbidden "Unexpected Origin."))
     ((and token (string=? path "/") (string=? (Request-method request) "GET")
           (secret=? token self.token))
      ;; Exchange the token for the cookie and drop it from the address bar.
      (ResponseHandler-write! response See-Other
                              [(cons "Location" "/")
                               (cons "Set-Cookie" (string-append self.cookie-name "=" self.session
                                                                 "; Path=/; HttpOnly; SameSite=Strict"))
                               (cons "Cache-Control" "no-store")
                               (cons "Referrer-Policy" "no-referrer")]
                              #u8()))
     ((let (session (cookie request self.cookie-name))
        (and session (secret=? session self.session)))
      (route self request response path))
     (else
      (respond-text response Forbidden "Open Tuna with the link it printed at startup.")))))

(def (route (self : web-transport) (request : Request) (response : ResponseHandler) (path : :string))
  => :void
  (let (method (Request-method request))
    (cond
     ((string=? path "/")
      (if (string=? method "GET")
        (ResponseHandler-write! response OK
                                '(("Content-Type" . "text/html; charset=utf-8")
                                  ("Cache-Control" . "no-store")
                                  ("Referrer-Policy" . "no-referrer"))
                                (string->utf8 (page-html (current-screen self))))
        (respond-text response Method-Not-Allowed "Use GET.")))
     ((string=? path "/screen")
      (if (and (string=? method "GET") (datastar-request? request))
        (stream-screens self request response)
        (respond-text response Bad-Request "Expected a Datastar GET.")))
     ((string=? path "/commands")
      (if (string=? method "POST")
        (accept-event self request response)
        (respond-text response Method-Not-Allowed "Use POST.")))
     ((and (string=? method "GET") (hash-get static-assets path))
      => (lambda ((asset : :pair))
           (ResponseHandler-write! response OK
                                   [(cons "Content-Type" (car asset))
                                    (cons "Cache-Control" "no-cache")]
                                   (:- (cdr asset) :u8vector))))
     (else
      (respond-text response Not-Found (string-append "Not found: " path))))))

;; One writer per client: send the newest screen whenever it changes.
(def (stream-screens (self : web-transport) (request : Request) (response : ResponseHandler)) => :void
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

(def (accept-event (self : web-transport) (request : Request) (response : ResponseHandler)) => :void
  (cond
   ((not (datastar-request? request))
    (respond-text response Bad-Request "Expected a Datastar request."))
   ((not (json-content-type? request))
    (respond-text response Unsupported-Media-Type "Expected JSON."))
   (else
    (let (event (with-catch (lambda (e) #f) (lambda () (parse-key-event (read-signals request)))))
      (if event
        (do-with-lock self.admission
          ;; Acknowledge, then enqueue, in arrival order across request threads.
          (ResponseHandler-write! response No-Content [] #u8())
          (parameterize ((current-kernel self.editor))
            (submit-event! event)))
        (respond-text response Bad-Request "Invalid event."))))))

(def (short-string? (value : :t)) => :boolean
  (and (string? value) (fx<= (string-length value) 64)))

(def (client-id? (value : :t)) => :boolean
  (and (string? value)
       (fx<= 1 (string-length value) 64)
       (andmap (lambda ((c : :char))
                 (or (char-alphabetic? c) (char-numeric? c) (memv c '(#\- #\_))))
               (string->list value))))

;; A validated keydown event, or #f.
(def (parse-key-event (value : :t)) => (Maybe key-event)
  (and (hash-table? value)
       (eqv? (hash-get value "version") 1)
       (equal? (hash-get value "type") "keydown")
       (let ((client (hash-get value "clientId"))
             (sequence (hash-get value "sequence"))
             (key (hash-get value "key"))
             (code (hash-get value "code"))
             (location (hash-get value "location"))
             (flags (map (lambda ((name : :string)) (hash-ref value name 'missing))
                         '("repeat" "isComposing" "altKey" "ctrlKey" "metaKey" "shiftKey"))))
         (and (client-id? client)
              (fixnum? sequence) (fx>= sequence 0)
              (short-string? key)
              (short-string? code)
              (fixnum? location) (fx<= 0 location 3)
              (andmap boolean? flags)
              (apply make-key-event client sequence key code location flags)))))

;;; The plugin

(def (stop-web-transport! (self : web-transport)) => :void
  (do-with-lock self.mutex
    (set! self.stopped? #t)
    (condition-variable-broadcast! self.changed))
  (Server-stop! (Server self.server)))

(defplugin (web-transport-plugin ctx)
  "Serves screens to browser tabs on loopback and receives their input."
  (let* ((port (let (configured (web-transport-listen-port))
                 (if (zero? configured) (free-loopback-port) configured)))
         (host (string-append "127.0.0.1:" (number->string port)))
         (self (web-transport editor: (current-kernel)
                              port: port
                              token: (new-secret)
                              session: (new-secret)
                              cookie-name: (string-append "tuna-" (number->string port))
                              host: host
                              origin: (string-append "http://" host)
                              admission: (make-mutex 'tuna-admission)
                              mutex: (make-mutex 'tuna-screen)
                              changed: (make-condition-variable 'tuna-screen)
                              screen: "<main id=\"screen\"></main>"
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
    (set! (web-transport-server self) server)
    (Server-start! server)
    (context-defer! ctx (lambda () (stop-web-transport! self)))
    (context-provide! ctx display-service self)))
