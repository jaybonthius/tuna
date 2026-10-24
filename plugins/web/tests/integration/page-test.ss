;;; The page service the web transport provides (contract.ss), over real
;;; loopback HTTP: a plugin's page script is on every page and served,
;;; with the files beside it, until the plugin turns off; a plugin's page
;;; address receives a tab's posts with the tab's client; a one-time
;;; instruction reaches only its client's page, after its next screen.
(import :std/io
        :std/net/address
        :std/test
        :std/time/timeout
        :tuna/kernel
        :tuna/plugins/clients/contract
        :tuna/plugins/web/contract
        :tuna/plugins/web/plugin
        "../support/web-client"
        (only-in "../../../../tuna/tests/support/string-input" test-input))
(export page-test)

;; What the page-user plugin's address received, newest first: (client
;; . body) pairs.
(def received [])

(defplugin (page-user ctx)
  "Adds a page script and a page address, for the page service's tests."
  requires: [page-service]
  (add-script "../support/page-script.js")
  (context-add-page-address! ctx "echo"
                             (lambda (c bytes)
                               (set! received (cons (cons c (utf8->string bytes)) received)))))

(def page-plugins [test-input web-transport page-user])

(def (post-to-address path body tab: (from (current-tab)) headers: (headers []))
  (http "POST" path
        headers: (append (if from [(cons "Tuna-Tab" from)] [])
                         [(cons "Content-Type" "application/octet-stream")]
                         headers)
        body: body))

;; The src of the page's module script whose file is FILE, or #f.
(def (script-src page file)
  (let (at (string-search (string-append file "\"") page))
    (and at
         (let lp ((start at))
           (if (string=? (substring page start (+ start 5)) "src=\"")
             (substring page (+ start 5) (+ at (string-length file)))
             (lp (- start 1)))))))

;; The /applied path of the last screen in TEXT.
(def (applied-path text)
  (let lp ((at 0) (last #f))
    (let (found (string-search-from "/applied?stream=" text at))
      (if found
        (lp (+ found 1) found)
        (let* ((end (string-index text #\' last))
               (path (substring text last end))
               (amp (string-search "&amp;" path)))
          (string-append (substring path 0 (+ amp 1))
                         (substring path (+ amp 5) (string-length path))))))))

(def (string-search-from needle text from)
  (let (at (string-search needle (substring text from (string-length text))))
    (and at (+ at from))))

(def (occurrences needle text)
  (let lp ((from 0) (n 0))
    (let (at (string-search-from needle text from))
      (if at (lp (+ at 1) (+ n 1)) n))))

(def page-test
  (test-suite "tuna/plugins/web page service"
    (test-case "a plugin's page script is on the page and served, with the files beside it, until it turns off"
      (with-web-tuna page-plugins
       (lambda ()
         (let* ((page (reply-body (http "GET" "/")))
                (src (script-src page "page-script.js")))
           (check (string? src) => #t)
           (check (string-prefix? "/js/" src) => #t)
           (check (and (string-search "<script type=\"module\" src=\"/static/tuna-input.js\"></script><script type=\"module\" src=\"/js/" page) #t) => #t)
           (let (reply (http "GET" src))
             (check (reply-status reply) => 200)
             (check (reply-header reply "Content-Type") => "text/javascript; charset=utf-8")
             (check (and (string-search "import \"./page-module.js\"" (reply-body reply)) #t) => #t))
           (let* ((beside (string-append (substring src 0 (+ 1 (string-rindex src #\/))) "page-module.js"))
                  (reply (http "GET" beside)))
             (check (reply-status reply) => 200)
             (check (reply-header reply "Content-Type") => "text/javascript; charset=utf-8"))
           (check (reply-status (http "GET" (string-append (substring src 0 (+ 1 (string-rindex src #\/)))
                                                         "../../../../plugin.ss")))
                  => 404)
           (call-on-editor-loop (lambda () (deactivate-plugin! page-user)))
           (check (script-src (reply-body (http "GET" "/")) "page-script.js") => #f)
           (check (reply-status (http "GET" src)) => 404)
           (check (reply-status (post-to-address "/plugin/page-user/echo" "late")) => 404)))))

    (test-case "a plugin's page address receives a tab's posts with the tab's client"
      (set! received [])
      (with-web-tuna page-plugins
       (lambda ()
         (let ((a (current-tab))
               (b (new-tab!)))
           (check (reply-status (post-to-address "/plugin/page-user/echo" "from a" tab: a)) => 204)
           (check (reply-status (post-to-address "/plugin/page-user/echo" "from b" tab: b)) => 204)
           (check (map (lambda (r) (cons (client-id (car r)) (cdr r))) (reverse received))
                  => [(cons a "from a") (cons b "from b")])
           ;; No tab, a tab the transport never made, another address, a
           ;; foreign origin: refused, and the handler is not called.
           (check (reply-status (post-to-address "/plugin/page-user/echo" "x" tab: #f)) => 400)
           (check (reply-status (post-to-address "/plugin/page-user/echo" "x" tab: "never-made")) => 400)
           (check (reply-status (post-to-address "/plugin/page-user/other" "x")) => 404)
           (check (reply-status (post-to-address "/plugin/page-user/echo" "x"
                                                 headers: [(cons "Origin" "https://evil.example")]))
                  => 403)
           (check (reply-status (http "GET" "/plugin/page-user/echo")) => 404)
           (check (length received) => 2)))))

    (test-case "a page instruction reaches only its client's page, once, after its next screen"
      (set! received [])
      (with-web-tuna page-plugins
       (lambda ()
         (let* ((a (current-tab))
                (b (new-tab!))
                (_ (post-to-address "/plugin/page-user/echo" "who" tab: a))
                (a-client (car (car received)))
                (a-stream (open-screen-stream tab: a))
                (b-stream (open-screen-stream tab: b))
                (a-first (read-until a-stream (cut string-search "data-revision" <>)))
                (b-first (read-until b-stream (cut string-search "data-revision" <>))))
           (check (reply-status (http "POST" (applied-path a-first)
                                      headers: [(cons "Datastar-Request" "true") (cons "Content-Type" "application/json")]
                                      body: (string-append "{\"tab\":\"" a "\"}")))
                  => 204)
           (call-on-editor-loop (lambda () (page-instruct! a-client "pageTest" (hash ("say" "<hi>")))))
           (let (text (read-until a-stream (cut string-search "pageTest" <>)))
             (check (occurrences "@pageTest(JSON.parse(el.textContent)); el.remove()" text) => 1)
             (check (and (string-search "data: selector body\ndata: mode append\n" text) #t) => #t)
             (check (and (string-search "{\"say\":\"&lt;hi&gt;\"}" text) #t) => #t))
           ;; Not again with the next screen, and never to B.
           (let (again (read-until a-stream (lambda (text) #f) seconds: 1.5))
             (check (occurrences "pageTest" again) => 0))
           (Socket-set-input-timeout! b-stream (IOTimeout 1.5))
           (check (occurrences "pageTest" (with-catch (lambda (e) "")
                                                      (lambda () (read-until b-stream (lambda (text) #f) seconds: 1.5))))
                  => 0)
           (check (with-catch (lambda (e) 'refused)
                              (lambda () (call-on-editor-loop (lambda () (page-instruct! a-client "bad name" #t)))))
                  => 'refused)
           (Socket-close a-stream)
           (Socket-close b-stream)))))))
