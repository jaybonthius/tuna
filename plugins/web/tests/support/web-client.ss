;;; A Tuna under test with the web transport on an ephemeral loopback
;;; port, and a minimal HTTP client that controls every header.
(import :std/error
        :std/io
        :std/net/address
        :std/time/timeout
        :tuna/kernel
        :tuna/plugins/web/plugin
        "../../../../tuna/tests/support/kernel")
(export with-web-tuna
        http
        post-key
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
        port
        token
        session-cookie)


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

;; Read until (DONE? text) or end of input.
(def (read-until socket done?)
  (let ((reader (StreamSocket-reader socket))
        (buffer (make-u8vector 4096)))
    (let lp ((chunks []))
      (let (text (utf8->string (apply u8vector-append (reverse chunks))))
        (if (done? text)
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
(def token #f)
(def session-cookie #f)

(def (host) (string-append "127.0.0.1:" (number->string port)))

(def (http method path headers: (headers []) body: (body "")
           host: (host-header (host)) cookie: (cookie session-cookie))
  (let (socket (connect port))
    (send! socket (request-text method path
                                (append [(cons "Host" host-header)]
                                        (if cookie [(cons "Cookie" cookie)] [])
                                        headers)
                                body))
    (let (text (read-until socket (lambda (text) #f)))
      (Socket-close socket)
      (parse-reply text))))

;; CHANGES replaces a raw JSON field, or omits it when its value is #f.
(def (keydown-json (key : :string) (ctrl? : :boolean) (sequence : :fixnum) . changes)
  => :string
  (let* ((fields [ (cons "version" "1") (cons "type" "\"keydown\"")
                  (cons "clientId" "\"web-test\"") (cons "sequence" (number->string sequence))
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

(def sequence 0)

(def (post-key key ctrl?: (ctrl? #f))
  (set! sequence (+ sequence 1))
  (http "POST" "/commands"
        headers: [(cons "Datastar-Request" "true") (cons "Content-Type" "application/json")]
        body: (keydown-json key ctrl? sequence)))

;; A pointer item as JSON: a left click on tab-line:30 on screen 0, with the
;; fields in CHANGES, each (name . raw-json), or (name . #f) to leave the
;; field out.
(def (pointer-json . changes)
  (let* ((fields '(("version" . "1") ("type" . "\"pointer\"") ("clientId" . "\"web-test\"")
                   ("sequence" . "1") ("revision" . "0") ("kind" . "\"click\"")
                   ("button" . "0") ("clicks" . "1")
                   ("modifiers" . "{\"alt\":false,\"ctrl\":false,\"meta\":false,\"shift\":false}")
                   ("target" . "\"tab-line:30\"") ("node" . "null")))
         (merged (filter cdr (map (lambda (field)
                                    (or (assoc (car field) changes) field))
                                  fields))))
    (string-append
     "{"
     (string-join (map (lambda (field) (string-append "\"" (car field) "\":" (cdr field))) merged) ",")
     "}")))

;; Post a left click on the part TARGET ("view:12") on screen REVISION, in
;; sequence after the keys post-key sent.
(def (post-click target revision: (revision 0) node: (node #f))
  (set! sequence (+ sequence 1))
  (http "POST" "/commands"
        headers: [(cons "Datastar-Request" "true") (cons "Content-Type" "application/json")]
        body: (pointer-json (cons "sequence" (number->string sequence))
                            (cons "revision" (number->string revision))
                            (cons "target" (string-append "\"" target "\""))
                            (cons "node" (if node (number->string node) "null")))))

;; The revision of the screen GET / shows.
(def (page-revision)
  (let* ((page (reply-body (http "GET" "/")))
         (start (+ (string-search "data-revision=\"" page) 15)))
    (string->number (substring page start (string-index page #\" start)))))

(def (open-screen-stream)
  (let (socket (connect port))
    (send! socket (request-text "GET" "/screen"
                                [(cons "Host" (host)) (cons "Cookie" session-cookie)
                                 (cons "Datastar-Request" "true")]
                                ""))
    socket))


;; Activate PLUGINS, which include the web transport, in a fresh kernel;
;; start the editor loop; exchange the launch token for the session
;; cookie; then call THUNK.
(def (with-web-tuna plugins thunk)
  (call-with-fresh-kernel plugins
    (lambda ()
      (start-editor-loop! quit-grace: 0.3)
      (let* ((url (web-transport-url))
             (colon (string-index url #\: 7))
             (slash (string-index url #\/ colon)))
        (set! port (string->number (substring url (+ colon 1) slash)))
        (set! token (substring url (+ (string-search "token=" url) 6) (string-length url))))
      (let (exchange (http "GET" (string-append "/?token=" token) cookie: #f))
        (set! session-cookie (car (string-split (reply-header exchange "Set-Cookie") #\;))))
      (thunk))))

