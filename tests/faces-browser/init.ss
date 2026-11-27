(import (tuna) (haml))
(use-plugin jobs)
(use-plugin document)
(use-plugin buffers)
(use-plugin commands)
(use-plugin web)
(use-plugin design-tokens)
(use-plugin faces)
(use-plugin views)
(use-plugin kill-ring)
(use-plugin keys)
(use-plugin ui)
(use-plugin layout)
(use-plugin repeat)
(use-plugin layout-split)
(use-plugin modes)
(use-plugin auto-mode)
(use-plugin files)
(use-plugin undo)
(use-plugin editing)
(use-plugin echo-area)
(use-plugin status-line)
(use-plugin minibuffer)
(use-plugin completion)
(use-plugin completion-list)
(use-plugin completion-annotations)
(use-plugin file-picker)
(use-plugin command-picker)
(use-plugin command-line)
(use-plugin transient)
(use-plugin prog)
(use-plugin syntax)
(use-plugin chez-scheme)
(use-plugin markdown)
(use-plugin chat)
(use-plugin dired)
(use-plugin python)
(use-plugin treesit)
(import (console))

(define default-excluded (treesit:excluded-captures))

;; Registering modus's stylesheet as the theme is all the modus plugin
;; does, so the test switches the theme without loading and unloading it.
(define (theme! on?)
  (if on?
      (tables:set! web:stylesheets 'theme (string-append (getenv "TUNA_LIBRARY") "/modus/src/modus/modus.css"))
      (tables:remove! web:stylesheets 'theme)))

(define (user-css! file) (tables:set! web:stylesheets 'user file))

(define (sv) (layout:selected-view))
(define (run-command c . args) (views:with-view (sv) (apply commands:run c args)))

(buffers:define-layer fixture-faces)
(buffers:define-layer fixture-matches (priority 10))

;; A text buffer's text starts at position 1, after its node's opening.
;; No plugin defines keyword.function: a name of keyword's family that
;; nothing styles takes the family's look.
(define fixture
  `((("if" ,faces:keyword) ("return" ,faces:keyword.return) ("def" keyword.function) ("#!r6rs" ,faces:keyword.directive)
     ("err" ,faces:error) ("warn" ,faces:warning) ("succ" ,faces:success) ("^M" ,faces:escape-glyph) ("C-x" ,faces:key-binding))
    (("car" ,faces:function.builtin) ("call" ,faces:function.call) ("get" ,faces:function.method.call) ("fn" ,faces:function)
     (";c" ,faces:comment) (";;;d" ,faces:comment.documentation) ("\"d\"" ,faces:string.documentation) ("\"s\"" ,faces:string) ("K" ,faces:constant))
    (("T" ,faces:type) ("int" ,faces:type.builtin) ("mod" ,faces:module) ("@at" ,faces:attribute) ("\\n" ,faces:string.escape) ("+add" ,faces:diff.plus))
    (("H1" ,faces:markup.heading.1) ("H2" ,faces:markup.heading.2) ("H3" ,faces:markup.heading.3) ("H4" ,faces:markup.heading.4)
     ("H5" ,faces:markup.heading.5) ("H6" ,faces:markup.heading.6) ("Hf" ,faces:markup.heading))
    (("S" ,faces:markup.strong) ("Q" ,faces:markup.quote) ("L" ,faces:markup.link) ("U" ,faces:markup.underline) ("I" ,faces:markup.italic) ("raw" ,faces:markup.raw))
    (("derr" ,faces:diagnostic.error) ("dwarn" ,faces:diagnostic.warning) ("dinfo" ,faces:diagnostic.info) ("dhint" ,faces:diagnostic.hint)
     ("dunn" ,faces:diagnostic.unnecessary) ("mt" ,faces:match) ("mo" ,faces:match.other))
    (("x" (,faces:markup.strong ,faces:keyword)) ("y" (,faces:markup.raw ,faces:keyword)) ("hkw" (,faces:keyword ,faces:markup.heading.1))
     ("hdir" (,faces:keyword.directive ,faces:markup.heading.1)) ("word" (,faces:keyword ,faces:diagnostic.error)))
    (("ab" #f) ("rkw" ,faces:keyword) ("r+" ,faces:diff.plus) ("rm" ,faces:match above) ("rka" ,faces:keyword above))
    (("mmrr" ,faces:match above))))

(define fixture-text
  (apply string-append
    (map (lambda (line)
           (string-append
             (let loop ([items line] [acc ""])
               (if (null? items) acc
                   (loop (cdr items) (string-append acc (if (string=? acc "") "" " ") (caar items)))))
             "\n"))
         fixture)))

(define (fixture-spans above?)
  (let loop ([lines fixture] [at 0] [acc '()])
    (if (null? lines)
        (reverse acc)
        (let next ([items (car lines)] [at at] [acc acc])
          (if (null? items)
              (loop (cdr lines) at acc)
              (let* ([item (car items)] [end (+ at (string-length (car item)))]
                     [acc (if (and (cadr item) (eq? above? (and (pair? (cddr item)) #t)))
                              (cons (list (+ at 1) (+ end 1) (list (cons 'face (cadr item)))) acc)
                              acc)])
                (next (cdr items) (+ end 1) acc)))))))

(define (fixture-position text)
  (let ([n (string-length text)] [m (string-length fixture-text)])
    (let loop ([i 0])
      (cond
        [(> (+ i n) m) #f]
        [(string=? (substring fixture-text i (+ i n)) text) i]
        [else (loop (+ i 1))]))))

(define (show-fixture)
  (let ([b (or (buffers:find "*faces*") (buffers:make "*faces*" fixture-text))])
    (buffers:set-spans! (buffers:layer b fixture-faces) 0 (+ (string-length fixture-text) 1) (fixture-spans #f))
    (buffers:set-spans! (buffers:layer b fixture-matches) 0 (+ (string-length fixture-text) 1) (fixture-spans #t))
    (layout:switch-to-buffer b)
    (no-region)
    #t))

(define (without-outer-diagnostic)
  (buffers:set-spans! (buffers:layer (buffers:find "*faces*") fixture-faces) 0 (+ (string-length fixture-text) 1)
    (map (lambda (s)
           (if (equal? (cdr (assq 'face (caddr s))) (list faces:keyword faces:diagnostic.error))
               (list (car s) (cadr s) (list (cons 'face faces:keyword)))
               s))
         (fixture-spans #f)))
  #t)

(define (no-region)
  (views:set-mark! (sv) #f)
  (views:set-point! (sv) (+ (string-length fixture-text) 1)))

(define (region from-text from-offset to-text)
  (views:set-mark! (sv) (+ (fixture-position from-text) from-offset 1))
  (views:set-point! (sv) (+ (fixture-position to-text) (string-length to-text) 1))
  #t)

(define (echo face text)
  (parameterize ([echo-area:face face]) (echo-area:message! text))
  #t)

(transient:define-menu faces-menu "Two entries whose keys the test reads.")

(transient:add! faces-menu "Files"
  (transient:command "a" "Find a file" file-picker:find-file)
  (transient:command "b" "Find another file" file-picker:find-file))

(define (show-menu) (transient:show! faces-menu) #t)

(define (hide-menu) (run-command transient:quit) #t)

(define (markdown-html text) (html->string (markdown:html text)))

(define (show-chat)
  (let ([b (or (buffers:find "*chat-fixture*")
               (buffers:make "*chat-fixture*"
                 '(chat:transcript ()
                    (chat:notice ((level . error)) "Failed")
                    (chat:diff () (chat:removed () "old") (chat:added () "new")))))])
    (layout:switch-to-buffer b)
    #t))

(define (visit path)
  (run-command file-picker:find-file path)
  (views:set-point! (sv) (- (document:length (buffers:document (views:buffer (sv)))) 1))
  #t)

(define (show-dired path)
  (run-command dired:open path)
  #t)

;; Matches are drawn in completion's faces under the any-order style.
(options:set! completion:styles (list completion:any-order))
