(import (tuna) (test) (haml) (markdown) (test-user) (buffers-test))

(define sample
  "# Title\n\nA *b* ~~c~~ `d`\nwrapped, then hard  \nbreak.\n\n```scheme extra\n(define x 1)\n```\n\n> quote\n\n- [ ] one\n- [x] two\n\n3. a\n4. b\n\n| a | b | c |\n|:-|:-:|-:|\n| 1 | 2 |\n\n---\n")

(test "every kind as datums: markers gone, a soft break a space, each line of text ending in a newline; list markers, task boxes and table lines are no text"
  (check-equal?
    '((markdown:heading ((key . 0) (level . 1)) "Title\n")
      (markdown:paragraph ((key . 1)) "A " (markdown:emphasis () "b") " " (markdown:strikethrough () "c") " " (markdown:code () "d")
                          " wrapped, then hard\nbreak.\n")
      (markdown:code-block ((key . 2) (language . "scheme")) "(define x 1)\n")
      (markdown:quote ((key . 3)) (markdown:paragraph ((key . 0)) "quote\n"))
      (markdown:list ((key . 4) (ordered . #f) (tight . #t))
                     (markdown:item ((key . 0) (task . unchecked)) (markdown:paragraph ((key . 0)) "one\n"))
                     (markdown:item ((key . 1) (task . checked)) (markdown:paragraph ((key . 0)) "two\n")))
      (markdown:list ((key . 5) (ordered . #t) (start . 3) (tight . #t))
                     (markdown:item ((key . 0)) (markdown:paragraph ((key . 0)) "a\n"))
                     (markdown:item ((key . 1)) (markdown:paragraph ((key . 0)) "b\n")))
      (markdown:table ((key . 6) (columns . 3))
                      (markdown:table-row ((key . 0) (header . #t)) (markdown:table-cell ((key . 0) (align . left)) "a\n")
                                          (markdown:table-cell ((key . 1) (align . center)) "b\n") (markdown:table-cell ((key . 2) (align . right)) "c\n"))
                      (markdown:table-row ((key . 1)) (markdown:table-cell ((key . 0) (align . left)) "1\n")
                                          (markdown:table-cell ((key . 1) (align . center)) "2\n") (markdown:table-cell ((key . 2) (align . right)) "\n")))
      #(markdown:rule ((key . 7))))
    (markdown:blocks sample)))

(test "images are links labelled by their description; other addresses, links in links, raw HTML and entities"
  (check-equal?
    '((markdown:paragraph ((key . 0)) (markdown:link ((href . "https://i.example/x.png")) "image") " "
                          (markdown:link ((href . "https://i.example/y.png")) "a b") " " (markdown:link ((href . "https://ci.example")) "badge") " "
                          (markdown:link ((href . "https://z.example")) "see https://x.example now") " main js "
                          (markdown:link ((href . "mailto:a@b.example")) "mailto:a@b.example") " <script>x</script> & ©\n"))
    (markdown:blocks
      "![](https://i.example/x.png) ![a *b*](https://i.example/y.png) [![badge](https://i.example/b.svg)](https://ci.example) [see https://x.example now](https://z.example) [main](src/main.ss) [js](javascript:alert(1)) <mailto:a@b.example> <script>x</script> &amp; &copy;")))

(test "the page's example of blocks"
  (check-equal? '((markdown:paragraph ((key . 0)) "See " (markdown:strong () "TSPL") ".\n")) (markdown:blocks "See **TSPL**.")))

(test "any thread may call the three procedures"
  (let ([r #f])
    (join-task (fork-task (lambda (restore) (set! r (list (markdown:blocks "a") (markdown:unfinished-blocks "*a") (html? (markdown:html "a")))))))
    (check-equal? '(((markdown:paragraph ((key . 0)) "a\n")) ((markdown:paragraph ((key . 0)) (markdown:emphasis () "a") "\n")) #t) r)))

(test "each procedure takes a string"
  (check-raises (buffers-test:raised-with? 'markdown:blocks "not a string" '(text)) (markdown:blocks 'text))
  (check-raises (buffers-test:raised-with? 'markdown:unfinished-blocks "not a string" '(#f)) (markdown:unfinished-blocks #f))
  (check-raises (buffers-test:raised-with? 'markdown:html "not a string" '(5)) (markdown:html 5)))

(define drawn (html->sxml (markdown:html sample)))

(define (classes-of class) (test-user:elements drawn class))

(define (attribute class name) (map (lambda (e) (test-user:element-attribute e name)) (classes-of class)))

(test "markdown:html draws the kinds' elements inside div.markdown, with no positions"
  (check-equal? 1 (length (classes-of "markdown")))
  (check-equal? '("heading") (attribute "markdown-heading" "role"))
  (check-equal? '("1") (attribute "markdown-heading" "aria-level"))
  (check-equal? '("Title\n") (map test-user:element-text (classes-of "markdown-heading")))
  (check-equal? '("b") (map test-user:element-text (classes-of "markdown-emphasis")))
  (check-equal? '("c") (map test-user:element-text (classes-of "markdown-strikethrough")))
  (check-equal? '("markup.raw") (attribute "markdown-code" "data-face"))
  (check-equal? '("scheme") (attribute "markdown-code-block" "data-language"))
  (check-equal? '("markup.raw") (attribute "markdown-code-block" "data-face"))
  (check-equal? '("quote\n") (map test-user:element-text (classes-of "markdown-quote")))
  (check-equal? '("list" "list") (attribute "markdown-list" "role"))
  (check-equal? '("" "") (attribute "markdown-list" "data-tight"))
  (check-equal? '("listitem" "listitem" "listitem" "listitem") (attribute "markdown-item" "role"))
  (check-equal? '(#f "") (attribute "markdown-item-box" "checked"))
  (check-equal? '("" "") (attribute "markdown-item-box" "disabled"))
  (check-equal? '("3." "4.") (map test-user:element-text (classes-of "markdown-item-marker")))
  (check-equal? '("table") (attribute "markdown-table" "role"))
  (check-equal? '("--markdown-table-columns:3") (attribute "markdown-table" "style"))
  (check-equal? '("" #f) (attribute "markdown-table-row" "data-header"))
  (check-equal? '("columnheader" "columnheader" "columnheader" "cell" "cell" "cell") (attribute "markdown-table-cell" "role"))
  (check-equal? '("left" "center" "right" "left" "center" "right") (attribute "markdown-table-cell" "data-align"))
  (check-equal? 1 (length (classes-of "markdown-rule")))
  (check-equal? '() (test-user:elements-with drawn "data-at")))

(test "markdown:html draws a link as span.markdown-link; an empty text is an empty div.markdown"
  (let ([links (test-user:elements (html->sxml (markdown:html "**Buy** [milk](https://shop.example)")) "markdown-link")])
    (check-equal? '("milk") (map test-user:element-text links))
    (check-equal? '(span) (map car links)))
  (let ([empty (test-user:elements (html->sxml (markdown:html "")) "markdown")])
    (check-equal? '("") (map test-user:element-text empty))))
