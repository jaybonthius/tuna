#!tuna
(import (lsp) (buffers) (document) (views) (layout) (files) (modes) (diagnostics) (completion) (keys) (web) (jsonrpc))

(define (now-ns)
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000000000) (time-nanosecond t))))

(define (median xs) (list-ref (list-sort < xs) (quotient (length xs) 2)))

(define (show name value) (printf "~a ~,2f\n" name value))

(define (ns-per-op n thunk)
  (median
    (map (lambda (k)
           (collect-rendezvous)
           (let ([start (now-ns)])
             (do ([i 0 (fx+ i 1)]) ((fx= i n)) (thunk))
             (/ (- (now-ns) start) (exact->inexact n))))
         (iota 9))))

(define home (getenv "HOME"))
(define tuna-program (car (command-line)))
(define libraries (string-append (path-parent tuna-program) "/libraries"))

(define (configure! name settings)
  (with-output-to-file (format "~a/~a.config" home name) (lambda () (write settings)) 'replace))

(define (fake-command name)
  (list tuna-program "--script" (string-append home "/fake-server.ss") libraries
        (format "~a/~a.config" home name) "/dev/null"))

(lsp:define-server bench (fake-command "bench"))

(define-table bench-keymap)
(define-hook bench-hook)
(modes:define-major-mode bench-mode (keymap bench-keymap) (hook bench-hook) (language "benchlang"))

(define (wait-until done?)
  (let loop ([n 0])
    (unless (or (done?) (= n 3000))
      (sleep-for 0.01)
      (loop (+ n 1)))))

(define project (string-append home "/project"))

(define (write-file! path content)
  (with-output-to-file path (lambda () (display content)) 'replace))

(define (lines n)
  (apply string-append (map (lambda (i) (format "line ~a with some words in it\n" i)) (iota n))))

(define (managed-buffer name content)
  (let ([path (string-append project "/" name)])
    (write-file! path content)
    (let ([b (files:visit path)])
      (modes:set-major-mode bench-mode b)
      (buffers:with-buffer b (lsp:ensure))
      (wait-until (lambda () (and (pair? (lsp:buffer-connections b))
                                  (lsp:connection-capability (car (lsp:buffer-connections b)) "textDocumentSync"))))
      b)))

(define (plain-buffer name content)
  (buffers:make name content))

(define (keystroke b p)
  (ns-per-op 200 (lambda () (buffers:replace! b p p "x") (buffers:replace! b p (fx+ p 1) ""))))

(define (run)
  (system (format "mkdir -p '~a/.git'" project))
  (set-option! lsp:send-changes-delay 1000)
  (configure! "bench" '((capabilities ("textDocumentSync" . 2) ("positionEncoding" . "utf-8") ("completionProvider" ("triggerCharacters" . #("."))))))
  (table-set! lsp:language-servers "benchlang" (list bench))
  (let* ([text (lines 10000)]
         [m (managed-buffer "big.bench" text)] [plain (plain-buffer "plain" text)]
         [middle (lambda (b) (document:line-start (buffers:document b) 5000))])
    (show "keystroke-plain-us" (/ (keystroke plain (middle plain)) 1000.0))
    (show "keystroke-managed-us" (/ (keystroke m (middle m)) 1000.0))
    (let* ([c (car (lsp:buffer-connections m))] [publish (table-ref lsp:notification-handlers "textDocument/publishDiagnostics")]
           [version (buffers:version m)]
           [params `(("uri" . ,(lsp:path->uri (files:path m))) ("version" . ,version)
                     ("diagnostics" . ,(list->vector (map (lambda (i) `(("range" ("start" ("line" . ,(* i 50)) ("character" . 5)) ("end" ("line" . ,(* i 50)) ("character" . 9)))
                                                                         ("severity" . 2) ("message" . "a problem")))
                                                          (iota 200)))))])
      (do ([i 0 (fx+ i 1)]) ((fx= i 10)) (buffers:replace! m 1 1 "\n"))
      (show "publish-200-ten-behind-ms" (/ (ns-per-op 5 (lambda () (publish c params))) 1000000.0)))
    (let* ([c (car (lsp:buffer-connections m))] [mb (make-string 1000000 #\a)]
           [params `(("textDocument" ("uri" . "file:///tmp/one-mb.bench") ("languageId" . "benchlang") ("version" . 0) ("text" . ,mb)))])
      (show "didopen-1mb-ms" (/ (ns-per-op 5 (lambda () (jsonrpc:notify c "textDocument/didOpen" params))) 1000000.0))))
  (let* ([path (string-append project "/raw.bench")])
    (call-with-port (open-file-output-port path (file-options no-fail))
      (lambda (p)
        (do ([i 0 (fx+ i 1)]) ((fx= i 5000)) (put-bytevector p (bytevector 97 255 10)))
        (put-bytevector p (string->utf8 "end\n"))))
    (let ([b (files:visit path)])
      (modes:set-major-mode bench-mode b)
      (buffers:with-buffer b (lsp:ensure))
      (wait-until (lambda () (pair? (lsp:buffer-connections b))))
      (show "keystroke-after-5000-raw-bytes-us" (/ (keystroke b (fx- (document:length (buffers:document b)) 2)) 1000.0))))
  (configure! "bench" `((capabilities ("textDocumentSync" . 2) ("completionProvider" ("triggerCharacters" . #("."))))
                        (responses ("textDocument/completion" . ,(list->vector (map (lambda (i) `(("label" . ,(format "item~a" i)))) (iota 5000)))))))
  (lsp:shutdown-all)
  (let* ([b (managed-buffer "complete.bench" "\n")] [client (web:add-client! 1)])
    (layout:switch-to-buffer b)
    (let ([view (layout:selected-view)])
      (views:set-point! view 1)
      (show "completion-5000-ms"
        (/ (median
             (map (lambda (k)
                    (let ([start (now-ns)])
                      (parameterize ([web:current-client client])
                        (views:call-with-view view (lambda () (completion:start-at-point 0))))
                      (let ([session (lambda () (views:call-with-view view completion:current-session))])
                        (wait-until (lambda () (let ([s (session)])
                                                 (and s (not (completion:session-busy? s))
                                                      (fx= 5000 (completion:matches-count (completion:session-matches s)))))))
                        (let ([t (- (now-ns) start)])
                          (completion:end! (session))
                          t))))
                  (iota 5)))
           1000000.0))))
  (let ([c (car (lsp:connections))] [publish (table-ref lsp:notification-handlers "textDocument/publishDiagnostics")])
    (for-each (lambda (i) (write-file! (format "~a/f~a.bench" project i) (lines 200))) (iota 200))
    (let ([start (now-ns)])
      (for-each
        (lambda (i)
          (publish c `(("uri" . ,(lsp:path->uri (format "~a/f~a.bench" project i)))
                       ("diagnostics" . ,(list->vector (map (lambda (j) `(("range" ("start" ("line" . ,(* j 10)) ("character" . 2)) ("end" ("line" . ,(* j 10)) ("character" . 6)))
                                                                          ("severity" . 1) ("message" . "storm")))
                                                            (iota 20)))))))
        (iota 200))
      (wait-until (lambda () (= 4000 (length (diagnostics:under project)))))
      (show "publish-storm-200-files-ms" (/ (- (now-ns) start) 1000000.0))))
  (lsp:shutdown-all))
