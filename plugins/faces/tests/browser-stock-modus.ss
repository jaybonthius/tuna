(import (tuna) (test) (test-browser) (test-runner) (cdp page) (design-tokens) (faces) (buffers) (document) (views) (layout)
        (layout-split) (editing) (echo-area) (status-line) (minibuffer) (files) (auto-mode) (file-picker) (options) (modes) (prog)
        (syntax) (chez-scheme) (python) (languages) (treesit) (tables) (treesit-test grammar) (faces-test))

(define install (path-parent (car (command-line))))

(define look-folder (string-append install "/plugins/faces/tests/look"))

(define home (getenv "HOME"))

(define (copy-file! from to)
  (let ([bytes (call-with-port (open-file-input-port from) get-bytevector-all)])
    (call-with-port (open-file-output-port to (file-options no-fail)) (lambda (p) (put-bytevector p bytes)))))

(let ([python python:python])
  (treesit-test/grammar:build-python! (languages:grammar-commit python) (treesit:grammar-file python)))

(for-each (lambda (name) (copy-file! (string-append look-folder "/" name) (string-append home "/" name))) '("look.py" "look.sls"))

(define (read-text path) (call-with-input-file path get-string-all))

(define page (test-browser:open (page-options [width 1400] [height 1000] [color-scheme (color-scheme light)])))

(define default-excluded (treesit:excluded-captures))

(define (visit! name)
  (let ([b (buffers:find name)]) (when b (buffers:kill! b)))
  (faces-test:run-command file-picker:find-file (string-append home "/" name))
  (let ([v (layout:selected-view)])
    (views:set-point! v (- (document:length (buffers:document (views:buffer v))) 1))))

(define (keyword-face? face) (and face (>= (string-length face) 7) (string=? "keyword" (substring face 0 7))))

(define (hex color)
  (let ([numbers (let loop ([chars (string->list color)] [digits '()] [found '()])
                   (cond
                     [(null? chars) (reverse (if (null? digits) found (cons (reverse digits) found)))]
                     [(char-numeric? (car chars)) (loop (cdr chars) (cons (car chars) digits) found)]
                     [(null? digits) (loop (cdr chars) '() found)]
                     [else (loop (cdr chars) '() (cons (reverse digits) found))]))])
    (apply string-append "#"
      (map (lambda (digits)
             (let ([s (number->string (string->number (list->string digits)) 16)])
               (string-downcase (if (= 1 (string-length s)) (string-append "0" s) s))))
           (list-head numbers 3)))))

(define (drawn-characters shot)
  (let ([id (format "view-~a" (views:id (layout:selected-view)))])
    (apply append
      (map (lambda (line)
             (append
               (apply append
                 (map (lambda (i)
                        (let* ([element (faces-test:parent shot i)]
                               [face (find (lambda (a) (faces-test:attribute shot a "data-face"))
                                           (cons element (faces-test:ancestors shot element)))]
                               [look (list (hex (faces-test:style shot element "color"))
                                           (if (>= (string->number (faces-test:style shot element "font-weight")) 600) "bold" "normal")
                                           (and face (faces-test:attribute shot face "data-face")))])
                          (map (lambda (c) (cons c look)) (string->list (faces-test:text shot i)))))
                      (filter (lambda (i) (string=? "#text" (faces-test:name shot i))) (faces-test:descendants shot line))))
               (list (list #\newline #f #f #f))))
           (filter (lambda (i) (faces-test:has-class? shot i "line"))
                   (faces-test:descendants shot (find (lambda (i) (equal? id (faces-test:attribute shot i "id")))
                                                      (faces-test:with-class shot "view"))))))))

;; No plugin tells when a buffer's highlighting has caught up with its
;; text, so the drawing is read once it shows a keyword and has stopped
;; changing.
(define (settled-characters)
  (let ([last #f] [since #f])
    (test-runner:wait-until
      (lambda ()
        (test-browser:wait-for-applied page)
        (let ([now (drawn-characters (faces-test:snapshot page))])
          (unless (equal? now last)
            (set! last now)
            (set! since (current-time 'time-monotonic)))
          (and (exists (lambda (c) (keyword-face? (cadddr c))) now)
               (time>? (current-time 'time-monotonic) (add-duration since (make-time 'time-duration 300000000 0)))))))
    last))

(define (split-tabs line)
  (let loop ([chars (string->list line)] [field '()] [fields '()])
    (cond
      [(null? chars) (reverse (cons (list->string (reverse field)) fields))]
      [(char=? #\tab (car chars)) (loop (cdr chars) '() (cons (list->string (reverse field)) fields))]
      [else (loop (cdr chars) (cons (car chars) field) fields)])))

(define (emacs-characters record size)
  (let ([looks (make-vector size #f)])
    (for-each
      (lambda (line)
        (unless (string=? line "")
          (let ([fields (split-tabs line)])
            (do ([i (string->number (car fields)) (+ i 1)]) ((= i (string->number (cadr fields))))
              (vector-set! looks i
                (list (string-downcase (list-ref fields 2))
                      (if (member (list-ref fields 3) '("bold" "semi-bold" "extra-bold" "ultra-bold")) "bold" "normal")
                      (list-ref fields 4)))))))
      (let loop ([lines '()] [p (open-input-string (read-text record))])
        (let ([l (get-line p)]) (if (eof-object? l) (reverse lines) (loop (cons l lines) p)))))
    looks))

(define (differences drawn record text)
  (let ([emacs (emacs-characters record (string-length text))] [n (string-length text)])
    (define (tuna-look i) (and (< i (length drawn)) (list-head (cdr (list-ref drawn i)) 2)))
    (define (emacs-look i) (let ([e (vector-ref emacs i)]) (and e (list-head e 2))))
    (define (comparable? i) (and (not (char-whitespace? (string-ref text i))) (tuna-look i) (emacs-look i)))
    (let loop ([i 0] [found '()])
      (cond
        [(>= i n) (reverse found)]
        [(or (not (comparable? i)) (equal? (tuna-look i) (emacs-look i))) (loop (+ i 1) found)]
        [else
         (let run ([j i])
           (if (and (< j n) (comparable? j) (equal? (tuna-look j) (tuna-look i)) (equal? (emacs-look j) (emacs-look i)))
               (run (+ j 1))
               (loop (max j (+ i 1))
                     (cons (list (substring text i (max j (+ i 1))) (tuna-look i) (emacs-look i)) found))))]))))

(define (drawn-text drawn) (list->string (map car drawn)))

(define (starts-with? s prefix)
  (and (>= (string-length s) (string-length prefix)) (string=? prefix (substring s 0 (string-length prefix)))))

(define (trim-end s)
  (let loop ([n (string-length s)])
    (if (and (> n 0) (char-whitespace? (string-ref s (- n 1)))) (loop (- n 1)) (substring s 0 n))))

(define python-text (read-text (string-append look-folder "/look.py")))

(define scheme-text (read-text (string-append look-folder "/look.sls")))

(define (record name) (string-append look-folder "/stock/" name))

(faces-test:show-fixture!)

(test "a method call is coloured as a function call, in faces' look and under Modus"
  (faces-test:set-case! page #f "")
  (options:set! treesit:excluded-captures '())
  (visit! "look.py")
  (settled-characters)
  (let ([exists-color (let ([shot (faces-test:snapshot page)])
                        (faces-test:style shot (faces-test:faced shot "exists" faces:function.method.call) "color"))])
    (faces-test:show-fixture!)
    (test-browser:wait-for-applied page)
    (let ([shot (faces-test:snapshot page)])
      (check-equal? (faces-test:style shot (faces-test:faced shot "call" faces:function.call) "color") exists-color)))
  (faces-test:set-case! page #t "")
  (let ([shot (faces-test:snapshot page)])
    (check-equal? (faces-test:style shot (faces-test:faced shot "call" faces:function.call) "color")
                  (faces-test:style shot (faces-test:faced shot "get" faces:function.method.call) "color")))
  (options:set! treesit:excluded-captures default-excluded))

;; chez-scheme tags text that scheme-mode leaves plain: a record type's
;; name, its fields, Chez's procedures, #f and a string's escape.
(define scheme-tagged '("point" "fields" "*" "display" "null?" "list" "car" "#f" "\\n"))

(for-each
  (lambda (constructs)
    (for-each
      (lambda (scheme)
        (test (format "Python and Scheme under Modus, ~a constructs in ~a, draw as stock Modus does in Emacs" constructs scheme)
          (faces-test:set-case! page #t (if (string=? constructs "bold") ":root { --modus-bold-constructs: bold; }" ""))
          (faces-test:color-scheme! page (string=? scheme "dark"))
          (for-each
            (lambda (level excluded)
              (options:set! treesit:excluded-captures excluded)
              (visit! "look.py")
              (let ([drawn (settled-characters)])
                (check-equal? (list level #t '())
                              (list level (starts-with? (drawn-text drawn) (trim-end python-text))
                                    (differences drawn (record (format "stock-~a-~a-~a-py.tsv" scheme constructs level)) python-text)))))
            '(3 4) (list default-excluded '()))
          (options:set! treesit:excluded-captures default-excluded)
          (visit! "look.sls")
          (let* ([drawn (settled-characters)]
                 [found (differences drawn (record (format "stock-~a-~a-3-sls.tsv" scheme constructs)) scheme-text)])
            (check (starts-with? (drawn-text drawn) (trim-end scheme-text)))
            (check-equal? '() (remp (lambda (run) (member (car run) scheme-tagged)) found))
            (check-equal? 11 (length found)))))
      '("light" "dark")))
  '("plain" "bold"))
