(import (tuna) (test) (test-runner) (test-user) (buffers) (document) (views) (layout) (keys) (commands) (options) (tables) (web) (editing)
        (kill-ring) (echo-area) (undo) (markdown) (buffers-test) (markdown-test page) (markdown-test notes))

(keys:bind! markdown:link-keys "C-c C-o" markdown:follow-link)

(define (view) (layout:selected-view))

(define (show! b)
  (views:set-buffer! (view) b)
  (views:set-point! (view) 1)
  (test-user:settle)
  b)

(define (datums b) (document:datums (buffers:document b)))

(define (text b) (document:text (buffers:document b)))

(define (shown class) (test-user:elements (test-user:screen) class))

(define (attributes class name) (map (lambda (e) (test-user:element-attribute e name)) (shown class)))

(define (texts class) (map test-user:element-text (shown class)))

(define (browsed) (map cdr (filter (lambda (call) (equal? "browse-url" (car call))) (test-user:take-page-calls!))))

(define sample
  "# Title\n\nA *b* ~~c~~ `d`\nwrapped, then hard  \nbreak.\n\n```scheme extra\n(define x 1)\n```\n\n> quote\n\n- [ ] one\n- [x] two\n\n3. a\n4. b\n\n| a | b | c |\n|:-|:-:|-:|\n| 1 | 2 |\n\n---\n")

(define b (show! (markdown-test/page:make "*sample*" sample)))

(test "in a buffer each kind draws its element, with its role and attributes"
  (check-equal? '(("heading" "1" "Title")) (map (lambda (e) (list (test-user:element-attribute e "role") (test-user:element-attribute e "aria-level")
                                                                (test-user:element-text e)))
                                               (shown "markdown-heading")))
  (check-equal? '("b" "c" "d") (append (texts "markdown-emphasis") (texts "markdown-strikethrough") (texts "markdown-code")))
  (check-equal? '(em del code) (map car (append (shown "markdown-emphasis") (shown "markdown-strikethrough") (shown "markdown-code"))))
  (check-equal? '("markup.raw") (attributes "markdown-code" "data-face"))
  (check-equal? '(("scheme" "markup.raw" "(define x 1)")) (map (lambda (e) (list (test-user:element-attribute e "data-language") (test-user:element-attribute e "data-face")
                                                                               (test-user:element-text e)))
                                                              (shown "markdown-code-block")))
  (check-equal? '(blockquote) (map car (shown "markdown-quote")))
  (check-equal? '("list" "list") (attributes "markdown-list" "role"))
  (check-equal? '("" "") (attributes "markdown-list" "data-tight"))
  (check-equal? '(#f "") (attributes "markdown-item-box" "checked"))
  (check-equal? '("3." "4.") (texts "markdown-item-marker"))
  (check-equal? '("--markdown-table-columns:3") (attributes "markdown-table" "style"))
  (check-equal? '("" #f) (attributes "markdown-table-row" "data-header"))
  (check-equal? '("columnheader" "columnheader" "columnheader" "cell" "cell" "cell") (attributes "markdown-table-cell" "role"))
  (check-equal? '("left" "center" "right" "left" "center" "right") (attributes "markdown-table-cell" "data-align"))
  (check-equal? '(hr) (map car (shown "markdown-rule"))))

(test "a table and a rule are whole, so a view never cuts them; a code block is not"
  (let ([holding (lambda (class) (length (filter (lambda (e) (pair? (test-user:elements e class))) (shown "whole"))))])
    (check-equal? '(1 1 0) (map holding '("markdown-table" "markdown-rule" "markdown-code-block")))))

(test "the kinds accept edits as text does"
  (views:set-point! (view) 2)
  (test-user:type! "New ")
  (check-equal? '(markdown:heading ((key . 0) (level . 1)) "New Title\n") (car (cddr (car (datums b))))))

(test "line motion reaches each block, the one after a list and after a quote included; at the end text goes before the last block's line break"
  (let ([stops (show! (markdown-test/page:make "*stops*" "- item one\n- item two\n\nAfter the list.\n\n> quoted\n\nEnd.\n"))]
        [walk (lambda (key n)
                (let loop ([k n] [at (list (views:point (view)))])
                  (if (= k 0) (reverse at) (begin (test-user:press! key) (loop (- k 1) (cons (views:point (view)) at))))))])
    (check-equal? '(4 17 30 49 59) (walk "C-n" 4))
    (check-equal? '(59 49 30 17 4) (walk "C-p" 4))
    (views:set-point! (view) 35)
    (test-user:press! "C-a")
    (check-equal? 30 (views:point (view)))
    (test-user:press! "M-> x C-p C-e !")
    (check-equal? "item one\nitem two\nAfter the list.\nquoted!\nEnd.x\n" (text stops))))

(define l (markdown-test/page:make "*copy*" "Some **bold** [link](https://l.example) and `code`."))

(test "a copy of rendered text is its visible text"
  (show! l)
  (views:set-point! (view) 2)
  (test-user:press! "C-SPC C-e M-w")
  (check-equal? "Some bold link and code." (kill-ring:text (kill-ring:current))))

(test "RET and a click on a link open its address in the browser that asked; a press on it leaves point where it is"
  (show! l)
  (test-user:take-page-calls!)
  (views:set-point! (view) 14)
  (test-user:press! "RET")
  (check-equal? '("https://l.example") (browsed))
  (views:set-point! (view) 3)
  (test-user:settle)
  (test-user:click! (view) 16)
  (check-equal? 3 (views:point (view)))
  (check-equal? '("https://l.example") (browsed)))

(test "the configuration's key on links follows the link at point"
  (show! (markdown-test/page:make "*links*" "Read [the guide](https://tuna.example/guide)."))
  (views:set-point! (view) 9)
  (test-user:take-page-calls!)
  (test-user:press! "C-c C-o")
  (check-equal? '("https://tuna.example/guide") (browsed)))

(test "follow-link needs a Markdown link"
  (show! l)
  (views:set-point! (view) 3)
  (check-equal? '((ui:pushed-button "no button is at the click or at point"))
                (map (lambda (c) (list (condition-who c) (condition-message c)))
                     (test-runner:reports-during (lambda () (views:call-with-view (view) (lambda () (commands:run markdown:follow-link)))))))
  (check-raises (buffers-test:raised? 'markdown:follow-link "not a Markdown link") (markdown:follow-link (document:token (buffers:document l) 1))))

(test "an atom drawn with markdown:html shows the drawing's elements"
  (show! (buffers:make "*notes*" (markdown-test/page:page '() (markdown-test/notes:note '((text . "**Buy** [milk](https://shop.example)"))))))
  (check-equal? '("Buy") (texts "markdown-strong"))
  (check-equal? '("milk") (texts "markdown-link"))
  (check-equal? '(span) (map car (shown "markdown-link"))))

(test "the stylesheet is markdown in web:stylesheets"
  (check-equal? "markdown/markdown.css" (tables:ref web:stylesheets 'markdown #f)))
