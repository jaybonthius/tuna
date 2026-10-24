;;; A Tuna under test with the web transport on an ephemeral loopback
;;; port, and a minimal HTTP client that controls every header.
(import :std/error
        :std/io
        :std/net/address
        :std/net/uri
        :std/time/timeout
        :tuna/kernel
        :tuna/plugins/web/plugin
        "../../../../tuna/tests/support/kernel")
(export with-web-tuna
        http
        current-tab
        new-tab!
        unknown-tab!
        post-key
        post-paste
        post-clipboard-report
        post-applied
        open-screen-stream
        read-until
        string-search
        reply-status
        reply-header
        reply-body
        keydown-json
        pointer-json
        post-click
        page-revision
        host
        port)


(defstruct reply (status headers body) final: #t)

(def (connect port)
  (let (socket (tcp-connect (string->address (string-append "inet4:127.0.0.1:" (number->string port)))))
    (Socket-set-input-timeout! socket (IOTimeout 5))
    socket))

(def (send! socket text)
  (Writer-write (StreamSocket-writer socket) (string->utf8 text)))

(def (request-text method path headers body)
  (string-append
   method " " path " HTTP/1.1\r\n"
   (apply string-append (map (lambda (h) (string-append (car h) ": " (cdr h) "\r\n")) headers))
   "Content-Length: " (number->string (u8vector-length (string->utf8 body))) "\r\n"
   "Connection: close\r\n\r\n"
   body))

;; Read until (DONE? text), end of input, or SECONDS have passed: a screen
;; stream re-sends an unconfirmed screen every second, so without a
;; deadline it would be read forever for a screen that never comes.
(def (read-until socket done? seconds: (seconds 20))
  (let ((reader (StreamSocket-reader socket))
        (buffer (make-u8vector 4096))
        (deadline (+ (time->seconds (current-time)) seconds)))
    (let lp ((chunks []))
      (let (text (utf8->string (apply u8vector-append (reverse chunks))))
        (if (or (done? text) (> (time->seconds (current-time)) deadline))
          text
          (let (count (with-catch (lambda (e) (if (premature-end-of-input-error? e) 0 (raise e)))
                                  (lambda () (Reader-read reader buffer 0 4096 1))))
            (if (zero? count)
              text
              (lp (cons (subu8vector buffer 0 count) chunks)))))))))

(def (parse-reply text)
  (let* ((split (string-search "\r\n\r\n" text))
         (head (string-split (substring text 0 split) #\newline))
         (status (string->number (cadr (string-split (car head) #\space)))))
    (make-reply status
                (map (lambda (line)
                       (let (colon (string-index line #\:))
                         (cons (substring line 0 colon)
                               (string-trim-cr (substring line (+ colon 2) (string-length line))))))
                     (cdr head))
                (substring text (+ split 4) (string-length text)))))

(def (string-search needle text)
  (let lp ((i 0))
    (cond
     ((> (+ i (string-length needle)) (string-length text)) #f)
     ((string=? needle (substring text i (+ i (string-length needle)))) i)
     (else (lp (+ i 1))))))

(def (string-trim-cr line)
  (if (and (> (string-length line) 0)
           (char=? (string-ref line (- (string-length line) 1)) #\return))
    (substring line 0 (- (string-length line) 1))
    line))

(def (reply-header reply name)
  (let (pair (find (lambda (h) (string-ci=? (car h) name)) (reply-headers reply)))
    (and pair (cdr pair))))

;;; The running Tuna under test

(def port #f)

(def (host) (string-append "127.0.0.1:" (number->string port)))

(def (http method path headers: (headers []) body: (body "")
           host: (host-header (host)))
  (let (socket (connect port))
    (send! socket (request-text method path
                                (append [(cons "Host" host-header)]
                                        headers)
                                body))
    (let (text (read-until socket (lambda (text) #f)))
      (Socket-close socket)
      (parse-reply text))))

;;; Tabs: every page names its tab (ADR 16)

;; The tab the helpers below send from unless told otherwise.
(def tab "tab-0")
(def tabs-made 0)
(def (current-tab) tab)

;; The last sequence number each tab sent.
(def sequences (make-hash-table))

;; Load the page, as a browser does: the server makes a new tab, numbered
;; from 1, whose id the page holds as its `tab` signal. Make that tab the
;; current one and return the page.
(def (load-page!)
  (let* ((page (reply-body (http "GET" "/")))
         (marker "data-signals:tab=\"'")
         (start (+ (string-search marker page) (string-length marker))))
    (set! tab (substring page start (string-index page #\' start)))
    page))

;; Load a page and return its new tab's id.
(def (new-tab!)
  (load-page!)
  tab)

;; Make the current tab one the server never made, as a page open across a
;; server restart has, and return its id.
(def (unknown-tab!)
  (set! tabs-made (+ tabs-made 1))
  (set! tab (string-append "unknown-" (number->string tabs-made)))
  tab)

(def (next-sequence! tab)
  (let (n (+ 1 (hash-ref sequences tab 0)))
    (hash-put! sequences tab n)
    n))

(def (tab-json tab) (string-append "\"" tab "\""))

;; CHANGES replaces a raw JSON field, or omits it when its value is #f.
(def (keydown-json (key : :string) (ctrl? : :boolean) (sequence : :fixnum) . changes)
  => :string
  (let* ((fields [ (cons "version" "1") (cons "tab" (tab-json tab)) (cons "type" "\"keydown\"")
                  (cons "sequence" (number->string sequence))
                  (cons "key" (string-append "\"" key "\"")) (cons "code" "\"\"")
                  (cons "location" "0") (cons "repeat" "false") (cons "isComposing" "false")
                  (cons "altKey" "false") (cons "ctrlKey" (if ctrl? "true" "false"))
                  (cons "metaKey" "false") (cons "shiftKey" "false")
                  (cons "isMac" "false") (cons "altLeft" "false")
                  (cons "altRight" "false") (cons "altGraph" "false")])
         (merged (filter cdr (map (lambda (field) (or (assoc (car field) changes) field)) fields))))
    (string-append "{"
                   (string-join (map (lambda (field) (string-append "\"" (car field) "\":" (cdr field)))
                                     merged) ",")
                   "}")))

(def (post-key key ctrl?: (ctrl? #f) alt?: (alt? #f) tab: (from tab))
  (http "POST" "/commands"
        headers: [(cons "Datastar-Request" "true") (cons "Content-Type" "application/json")]
        body: (keydown-json key ctrl? (next-sequence! from) (cons "tab" (tab-json from))
                            (cons "altKey" (if alt? "true" "false")))))

;; Post a paste item from tab FROM: TEXT-JSON, raw JSON, is its text.
(def (post-paste text-json tab: (from tab))
  (http "POST" "/commands"
        headers: [(cons "Datastar-Request" "true") (cons "Content-Type" "application/json")]
        body: (string-append "{\"version\":1,\"tab\":" (tab-json from) ",\"type\":\"paste\","
                             "\"sequence\":" (number->string (next-sequence! from)) ","
                             "\"text\":" text-json "}")))

;; Post a clipboard report from tab FROM: OUTCOME and REASON are raw JSON.
(def (post-clipboard-report outcome reason: (reason "null") tab: (from tab))
  (http "POST" "/commands"
        headers: [(cons "Datastar-Request" "true") (cons "Content-Type" "application/json")]
        body: (string-append "{\"version\":1,\"tab\":" (tab-json from) ",\"type\":\"clipboard\","
                             "\"sequence\":" (number->string (next-sequence! from)) ","
                             "\"outcome\":" outcome ",\"reason\":" reason "}")))

;; Post PATH, a screen's /applied path, as tab FROM's page does.
(def (post-applied path tab: (from tab))
  (http "POST" path
        headers: [(cons "Datastar-Request" "true") (cons "Content-Type" "application/json")]
        body: (string-append "{\"tab\":" (tab-json from) "}")))

;; A pointer item as JSON: a left click on tab-line:30 on screen 0 from the
;; current tab, with the fields in CHANGES, each (name . raw-json), or (name
;; . #f) to leave the field out.
(def (pointer-json . changes)
  (let* ((fields `(("version" . "1") ("tab" . ,(tab-json tab)) ("type" . "\"pointer\"")
                   ("sequence" . "1") ("revision" . "0") ("kind" . "\"click\"")
                   ("button" . "0") ("clicks" . "1")
                   ("modifiers" . "{\"alt\":false,\"ctrl\":false,\"meta\":false,\"shift\":false}")
                   ("target" . "\"tab-line:30\"") ("node" . "null") ("line" . "null")))
         (merged (filter cdr (map (lambda (field)
                                    (or (assoc (car field) changes) field))
                                  fields))))
    (string-append
     "{"
     (string-join (map (lambda (field) (string-append "\"" (car field) "\":" (cdr field))) merged) ",")
     "}")))

;; Post a left click on the part TARGET ("view:12") on screen REVISION from
;; tab FROM, in sequence after the keys post-key sent.
(def (post-click target revision: (revision 0) node: (node #f) tab: (from tab))
  (http "POST" "/commands"
        headers: [(cons "Datastar-Request" "true") (cons "Content-Type" "application/json")]
        body: (pointer-json (cons "tab" (tab-json from))
                            (cons "sequence" (number->string (next-sequence! from)))
                            (cons "revision" (number->string revision))
                            (cons "target" (string-append "\"" target "\""))
                            (cons "node" (if node (number->string node) "null")))))

;; The revision of the screen GET / shows. Loading the page makes a new
;; tab, numbered from 1, as a browser reload does.
(def (page-revision)
  (let* ((page (load-page!))
         (start (+ (string-search "data-revision=\"" page) 15)))
    (string->number (substring page start (string-index page #\" start)))))

;; Open tab FROM's screen stream, as Datastar does, with its signals in
;; the datastar query parameter.
(def (open-screen-stream tab: (from tab))
  (let (socket (connect port))
    (send! socket (request-text "GET" (string-append "/screen?datastar="
                                                     (uri-encode (string-append "{\"tab\":" (tab-json from) "}")))
                                [(cons "Host" (host))
                                 (cons "Datastar-Request" "true")]
                                ""))
    socket))


;; Activate PLUGINS, which include the web transport, in a fresh kernel;
;; start the editor loop; load the page unless LOAD-PAGE? is #f (a page
;; left open across a server restart); then call THUNK at its plain URL.
(def (with-web-tuna plugins thunk load-page?: (load-page? #t))
  (call-with-fresh-kernel plugins
    (lambda ()
      (start-editor-loop! quit-grace: 0.3)
      (let* ((url (web-transport-url))
             (colon (string-index url #\: 7))
             (slash (string-index url #\/ colon)))
        (set! port (string->number (substring url (+ colon 1) slash))))
      (if load-page? (load-page!) (unknown-tab!))
      (thunk))))

