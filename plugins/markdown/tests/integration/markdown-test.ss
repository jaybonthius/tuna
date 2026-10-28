;;; The markdown plugin through its contract, on the real buffers plugin:
;;; Markdown as nodes (text nodes with styled spans, links, tables),
;;; rebuilding only the blocks that changed, and styling a text being
;;; typed again after each change.
(import :std/test
        :tuna/kernel
        :tuna/plugins/buffers/contract
        :tuna/plugins/markdown/contract
        :tuna/plugins/text-store/plugin
        :tuna/plugins/settings/plugin
        :tuna/plugins/buffers/plugin
        :tuna/plugins/markdown/plugin
        "../../../../tuna/tests/support/kernel")
(export markdown-test)

(def markdown-plugins [rope-text-store settings buffers markdown])

;; The kinds of NODES and of their children, as nested lists.
(def (kinds (nodes : :list)) => :list
  (map (lambda ((n : node))
         (if (text-node? n)
           'text
           (cons (node-kind n) (kinds (node-children n)))))
       nodes))

;; The text of the first text node at N and its markdown highlights as
;; (START END FACE).
(def (styled-text (n : node)) => :list
  (let (t (text-node-content (first-text-node n)))
    [(text-string t)
     (map (lambda ((s : span)) [s.start s.end s.value]) (text-highlights t 'markdown))]))

(def markdown-test
  (test-suite "tuna/plugins/markdown"
    (test-case "blocks become nodes; a paragraph is text with its inline styles as spans, then its links"
      (call-with-fresh-kernel markdown-plugins
       (lambda ()
         (let (nodes (markdown-blocks "# Title\n\nSome **bold** and a [link](https://example.org)."))
           (check (kinds nodes) => '((markdown-heading text) (markdown-paragraph text (markdown-links))))
           (check (map (cut node-attribute <> 'key) nodes) => [0 1])
           (check (map (cut node-attribute <> 'markdown) nodes)
                  => ["# Title" "Some **bold** and a [link](https://example.org)."])
           (check (node-attribute (car nodes) 'level) => 1)
           (check (styled-text (cadr nodes))
                  => ["Some bold and a link." '((6 10 markdown-strong) (17 21 markdown-link))])
           (check (node-attribute (cadr (node-children (cadr nodes))) 'links)
                  => '(("link" . "https://example.org")))
           ;; The links open in a new browser tab, without the page.
           (check ((node-renderer 'markdown-links) (cadr (node-children (cadr nodes))) [])
                  => '(p (@ (class "markdown-links"))
                         (a (@ (class "markdown-link") (href "https://example.org") (title "https://example.org")
                               (target "_blank") (rel "noopener noreferrer") (tabindex "-1"))
                            "link")))))))

    (test-case "raw HTML is text and an unsafe link is its label, with no link"
      (call-with-fresh-kernel markdown-plugins
       (lambda ()
         (let (nodes (markdown-blocks "<script>alert(1)</script> [x](javascript:alert(1)) <img src=x onerror=alert(1)>"))
           (check (kinds nodes) => '((markdown-paragraph text)))
           (check (styled-text (car nodes))
                  => ["<script>alert(1)</script> x <img src=x onerror=alert(1)>" '()])))))

    (test-case "code is a text of its lines; lists, items and quotes hold blocks"
      (call-with-fresh-kernel markdown-plugins
       (lambda ()
         (let (nodes (markdown-blocks "```scheme\n(a)\n(b)\n```\n\n- one\n- [x] two\n\n> said"))
           (check (kinds nodes)
                  => '((markdown-code text)
                       (markdown-list (markdown-item (markdown-paragraph text))
                                      (markdown-item (markdown-paragraph text)))
                       (markdown-quote (markdown-paragraph text))))
           (check (node-attribute (car nodes) 'language) => "scheme")
           (check (text-string (text-node-content (first-text-node (car nodes)))) => "(a)\n(b)")
           (check (map node-text-projection (node-children (cadr nodes))) => ["• one" "[x] two"])))))

    (test-case "a table is one item, its text a row a line with cells apart by tabs"
      (call-with-fresh-kernel markdown-plugins
       (lambda ()
         (let (nodes (markdown-blocks "| a | b |\n|:--|--:|\n| 1 | **2** |"))
           (check (kinds nodes) => '((markdown-table)))
           (check (node-text-projection (car nodes)) => "a\tb\n1\t2")
           (check (node-attribute (car nodes) 'alignments) => '(left right))
           (check (node-attribute (car nodes) 'rows) => '((("1") ((strong "2")))))))))

    (test-case "updating keeps the nodes of unchanged blocks, as when a reply streams in"
      (call-with-fresh-kernel markdown-plugins
       (lambda ()
         (let* ((holder (new-node 'holder))
                (first (markdown-blocks "# Title\n\nOne.\n\nTw")))
           (set-node-children! holder first)
           (let (second (markdown-update-blocks (node-children holder) "# Title\n\nOne.\n\nTwo, then more."))
             (set-node-children! holder second)
             (check (map eq? first second) => [#t #t #f])
             (check (styled-text (caddr second)) => ["Two, then more." '()])
             ;; A block that moves to another key is rebuilt.
             (let (third (markdown-update-blocks (node-children holder) "One.\n\nTwo, then more."))
               (check (length third) => 2)
               (check (ormap (lambda (n) (memq n second)) third) => #f)))))))

    (test-case "a styled text is styled again after each change"
      (call-with-fresh-kernel markdown-plugins
       (lambda ()
         (let (t (new-text "plain"))
           (markdown-style-text! t)
           (check (text-highlights t 'markdown) => '())
           (text-replace! t 1 1 "# ")
           (check (map (lambda ((s : span)) [s.start s.end s.value]) (text-highlights t 'markdown))
                  => '((1 3 markdown-heading-1-marker) (3 8 markdown-heading-1)))
           (text-replace! t 1 3 "")
           (check (text-highlights t 'markdown) => '())))))))
