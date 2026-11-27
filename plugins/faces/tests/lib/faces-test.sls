#!tuna
(import (tables) (web) (buffers) (document) (views) (layout) (commands) (faces) (markdown) (dired) (haml)
        (test-browser) (test-runner) (cdp) (cdp page))

(buffers:define-layer fixture-faces)

(buffers:define-layer fixture-matches (priority 10))

;; A text buffer's text starts at position 1, after its node's opening.
;; No plugin defines keyword.function: a name of keyword's family that
;; nothing styles takes the family's look.
(define fixture
  `((("if" ,faces:keyword) ("return" ,faces:keyword.return) ("def" keyword.function) ("#!r6rs" ,faces:keyword.directive)
     ("err" ,faces:error) ("warn" ,faces:warning) ("succ" ,faces:success) ("^M" ,faces:escape-glyph) ("C-x" ,faces:key-binding))
    (("car" ,faces:function.builtin) ("call" ,faces:function.call) ("get" ,faces:function.method.call) ("fn" ,faces:function)
     (";c" ,faces:comment) (";;;d" ,faces:comment.documentation) ("\"d\"" ,faces:string.documentation) ("\"s\"" ,faces:string)
     ("K" ,faces:constant))
    (("T" ,faces:type) ("int" ,faces:type.builtin) ("mod" ,faces:module) ("@at" ,faces:attribute) ("\\n" ,faces:string.escape)
     ("+add" ,faces:diff.plus))
    (("H1" ,faces:markup.heading.1) ("H2" ,faces:markup.heading.2) ("H3" ,faces:markup.heading.3) ("H4" ,faces:markup.heading.4)
     ("H5" ,faces:markup.heading.5) ("H6" ,faces:markup.heading.6) ("Hf" ,faces:markup.heading))
    (("S" ,faces:markup.strong) ("Q" ,faces:markup.quote) ("L" ,faces:markup.link) ("U" ,faces:markup.underline)
     ("I" ,faces:markup.italic) ("raw" ,faces:markup.raw))
    (("derr" ,faces:diagnostic.error) ("dwarn" ,faces:diagnostic.warning) ("dinfo" ,faces:diagnostic.info)
     ("dhint" ,faces:diagnostic.hint) ("dunn" ,faces:diagnostic.unnecessary) ("mt" ,faces:match) ("mo" ,faces:match.other))
    (("x" (,faces:markup.strong ,faces:keyword)) ("y" (,faces:markup.raw ,faces:keyword)) ("hkw" (,faces:keyword ,faces:markup.heading.1))
     ("hdir" (,faces:keyword.directive ,faces:markup.heading.1)) ("word" (,faces:keyword ,faces:diagnostic.error)))
    (("ab" #f) ("rkw" ,faces:keyword) ("r+" ,faces:diff.plus) ("rm" ,faces:match above) ("rka" ,faces:keyword above))
    (("mmrr" ,faces:match above))))

(define items (apply append (list-head fixture 6)))

(define fixture-text
  (call-with-string-output-port
    (lambda (p)
      (for-each
        (lambda (line)
          (put-string p (car (car line)))
          (for-each (lambda (item) (put-string p " ") (put-string p (car item))) (cdr line))
          (put-string p "\n"))
        fixture))))

(define (%spans above?)
  (let loop ([lines fixture] [at 0] [acc '()])
    (if (null? lines)
        (reverse acc)
        (let next ([line (car lines)] [at at] [acc acc])
          (if (null? line)
              (loop (cdr lines) at acc)
              (let* ([item (car line)] [end (+ at (string-length (car item)))])
                (next (cdr line) (+ end 1)
                      (if (and (cadr item) (eq? above? (pair? (cddr item))))
                          (cons (list (+ at 1) (+ end 1) (list (cons 'face (cadr item)))) acc)
                          acc))))))))

(define (%fixture-position text)
  (let ([n (string-length text)] [m (string-length fixture-text)])
    (let loop ([i 0])
      (cond
        [(> (+ i n) m) (assertion-violation 'faces-test:region! "not in the fixture" text)]
        [(string=? (substring fixture-text i (+ i n)) text) i]
        [else (loop (+ i 1))]))))

(define (%view) (layout:selected-view))

(define (%end) (+ (string-length fixture-text) 1))

(define (no-region!)
  (views:set-mark! (%view) #f)
  (views:set-point! (%view) (%end)))

(define (show-fixture!)
  (let ([b (or (buffers:find "*faces*") (buffers:make "*faces*" fixture-text))])
    (buffers:set-spans! (buffers:layer b fixture-faces) 0 (%end) (%spans #f))
    (buffers:set-spans! (buffers:layer b fixture-matches) 0 (%end) (%spans #t))
    (layout:switch-to-buffer b)
    (no-region!)))

(define (without-outer-diagnostic!)
  (buffers:set-spans! (buffers:layer (buffers:find "*faces*") fixture-faces) 0 (%end)
    (map (lambda (s)
           (if (equal? (cdr (assq 'face (caddr s))) (list faces:keyword faces:diagnostic.error))
               (list (car s) (cadr s) (list (cons 'face faces:keyword)))
               s))
         (%spans #f))))

(define (region! from-text from-offset to-text)
  (views:set-mark! (%view) (+ (%fixture-position from-text) from-offset 1))
  (views:set-point! (%view) (+ (%fixture-position to-text) (string-length to-text) 1)))

(define (run-command command . arguments)
  (views:with-view (%view) (apply commands:run command arguments)))

;; No plugin draws a faced strong element, nor transient's key in the
;; key-binding face, and Markdown's drawing of text has no buffer of its
;; own, so a node of the test's draws them.
(buffers:define-kind %samples
  (content nodes)
  (draw (lambda (node view)
          (haml (:div (:strong ([data-face (symbol->string faces:keyword)]) "ua")
                      (:kbd.transient-key ([data-face (symbol->string faces:key-binding)]) "b")
                      (markdown:html "Some `code` here.\n\n```\nblock\n```\n"))))))

(define (show-samples!)
  (layout:switch-to-buffer (or (buffers:find "*samples*") (buffers:make "*samples*" (%samples '())))))

(define %cases 0)

;; A stylesheet comes to the page as a link, which loads after the page
;; has applied it, so each case's file sets a mark its computed style
;; shows once loaded, and the theme is in once its palette is.
(define (set-case! page theme? css)
  (unless (string? css) (assertion-violation 'faces-test:set-case! "not a string" css))
  (set! %cases (+ %cases 1))
  (let ([file (format "~a/case-~a.css" (getenv "HOME") %cases)] [theme (module-owner '(modus))])
    (call-with-output-file file
      (lambda (p) (fprintf p "~a\n:root { --faces-test-case: ~a; }\n" css %cases)))
    (cond
      [(and theme? (not theme)) (load-module! '(modus))]
      [(and (not theme?) theme) (unload-owner! theme)])
    (tables:set! web:stylesheets 'user file)
    (let ([want (list (number->string %cases) theme?)])
      (test-runner:wait-until
        (lambda ()
          (equal? want
                  (test-browser:call
                    (lambda ()
                      (let ([root (car (page-query page "html"))])
                        (list (element-style root "--faces-test-case")
                              (and (element-style root "--modus-fg-main") #t)))))))))
    (test-browser:wait-for-applied page)))

(define (color-scheme! page dark?)
  (test-browser:call
    (lambda ()
      (cdp-call (page-session page) "Emulation.setEmulatedMedia"
        `(("features" . #((("name" . "prefers-color-scheme") ("value" . ,(if dark? "dark" "light"))))))))))

(define properties
  '("color" "background-color" "font-weight" "font-style" "font-family" "font-size" "text-decoration-line"
    "text-decoration-style" "text-decoration-color" "display" "visibility"))

(define-record-type %shot
  (sealed #t)
  (fields nodes children))

(define (snapshot page)
  (let* ([nodes (test-browser:call (lambda () (page-snapshot page properties)))]
         [children (make-vector (vector-length nodes) '())])
    (let loop ([i (fx- (vector-length nodes) 1)])
      (when (fx>= i 0)
        (let ([parent (snapshot-node-parent (vector-ref nodes i))])
          (when parent
            (vector-set! children parent (cons i (vector-ref children parent)))))
        (loop (fx- i 1))))
    (make-%shot nodes children)))

(define (%node shot i) (vector-ref (%shot-nodes shot) i))

(define (name shot i) (snapshot-node-name (%node shot i)))

(define (attribute shot i attribute-name)
  (let ([a (assoc attribute-name (snapshot-node-attributes (%node shot i)))])
    (and a (cdr a))))

(define (text shot i)
  (call-with-string-output-port
    (lambda (p)
      (let walk ([i i])
        (if (string=? "#text" (snapshot-node-name (%node shot i)))
            (put-string p (snapshot-node-value (%node shot i)))
            (for-each walk (vector-ref (%shot-children shot) i)))))))

(define (%words value)
  (let loop ([chars (string->list value)] [word '()] [words '()])
    (let ([add (lambda () (if (null? word) words (cons (list->string (reverse word)) words)))])
      (cond
        [(null? chars) (reverse (add))]
        [(char-whitespace? (car chars)) (loop (cdr chars) '() (add))]
        [else (loop (cdr chars) (cons (car chars) word) words)]))))

(define (%nodes-where shot keep?)
  (filter keep? (iota (vector-length (%shot-nodes shot)))))

(define (has-class? shot i class)
  (let ([v (attribute shot i "class")]) (and v (member class (%words v)) #t)))

(define (with-class shot class)
  (%nodes-where shot (lambda (i) (has-class? shot i class))))

(define (with-face shot face)
  (let ([face-name (symbol->string face)])
    (%nodes-where shot (lambda (i) (equal? face-name (attribute shot i "data-face"))))))

(define (faced shot item-text face)
  (or (find (lambda (i) (string=? item-text (text shot i))) (with-face shot face))
      (errorf 'faces-test:faced "no ~a drawn in ~a" item-text face)))

(define (look shot i)
  (let ([styles (snapshot-node-styles (%node shot i))])
    (when (null? styles)
      (errorf 'faces-test:look "~a is not laid out" (snapshot-node-name (%node shot i))))
    styles))

(define (style shot i property)
  (cdr (or (assoc property (look shot i))
           (assertion-violation 'faces-test:style "a property not read" property))))

(define (family shot i)
  (let* ([families (style shot i "font-family")]
         [comma (let loop ([k 0]) (cond [(= k (string-length families)) k] [(char=? #\, (string-ref families k)) k] [else (loop (+ k 1))]))]
         [first (substring families 0 comma)])
    (if (and (> (string-length first) 1) (char=? #\" (string-ref first 0)))
        (substring first 1 (- (string-length first) 1))
        first)))

(define (parent shot i) (snapshot-node-parent (%node shot i)))

(define (ancestors shot i)
  (let ([p (parent shot i)])
    (if p (cons p (ancestors shot p)) '())))

(define (inside? shot i j) (and (memv j (ancestors shot i)) #t))

(define (descendants shot i)
  (apply append (map (lambda (c) (cons c (descendants shot c))) (vector-ref (%shot-children shot) i))))

(define (item-looks shot)
  (map (lambda (item) (cons (cadr item) (look shot (faced shot (car item) (cadr item))))) items))

(define (wait-for page selector)
  (test-browser:call (lambda () (page-wait-for page selector (element-state attached))))
  (test-browser:wait-for-applied page))

;; A quit key at a prompt is read as a key, whose binding ends the
;; prompt and so cancels the command whose key opened it.
(define (quit-prompt! page)
  (let* ([reported '()] [keep (lambda (next c) (set! reported (cons c reported)))])
    (advice-add! report keep)
    (test-browser:press! page "C-g")
    (advice-remove! report keep)
    (unless (and (= 1 (length reported)) (cancelled? (car reported)) (not (cancelled-reason (car reported))))
      (errorf 'faces-test:quit-prompt! "C-g reported ~s, not the cancel of the prompt's command" reported))))

;; find-file's row in M-x's list shows its key and its documentation.
(define (completion-rows page)
  (test-browser:press! page "M-x")
  (test-browser:type! page "find-fi")
  (wait-for page ".completion-column[data-face=\"shadow\"]")
  (wait-for page ".completion-list-count")
  (let ([shot (snapshot page)])
    (quit-prompt! page)
    shot))

(define (%write-file! path text)
  (call-with-output-file path (lambda (p) (put-string p text)) 'replace))

(define (dired-folder)
  (let ([folder (string-append (getenv "HOME") "/folder")])
    (unless (file-directory? folder)
      (mkdir folder)
      (mkdir (string-append folder "/sub"))
      (for-each (lambda (name) (%write-file! (string-append folder "/" name) (string-append name "\n")))
                '("a.txt" "b.txt" "c.txt")))
    (string-append folder "/")))

(define %dired-marked? #f)

(define (dired-shot page)
  (run-command dired:open (dired-folder))
  (unless %dired-marked?
    (run-command dired:mark 1)
    (run-command dired:flag-deletion 1)
    (set! %dired-marked? #t))
  (test-browser:wait-for-applied page)
  (let ([shot (snapshot page)])
    (show-fixture!)
    (test-browser:wait-for-applied page)
    shot))
