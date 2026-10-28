;;; The highlight spans that style Markdown being typed (style.ss): what
;;; each kind of block and span looks like, its marks dimmed, and text
;;; that is not Markdown left alone.
(import :std/test
        :tuna/plugins/buffers/contract
        :tuna/plugins/markdown/style)
(export style-test)

;; SOURCE's spans as (START END FACE), positions from 1.
(def (spans (source : :string)) => :list
  (map (lambda ((s : span)) [s.start s.end s.value]) (markdown-style-spans source)))

(def style-test
  (test-suite "tuna/plugins/markdown/style"
    (test-case "a heading is larger, its # dimmed; bold and code look as drawn, their delimiters dimmed"
      (check (spans "# Title\n\nSome **bold** and `code`.")
             => '((1 3 markdown-heading-1-marker) (3 8 markdown-heading-1)
                  (15 17 markdown-strong-marker) (17 21 markdown-strong) (21 23 markdown-strong-marker)
                  (28 29 markdown-code-marker) (29 33 markdown-code) (33 34 markdown-code-marker))))

    (test-case "a setext heading's underline is a mark"
      (check (spans "Title\n===")
             => '((1 7 markdown-heading-1) (7 10 markdown-heading-1-marker))))

    (test-case "quote marks, bullets and numbers are marks; emphasis is italic"
      (check (spans "> quote *em*\n- item\n1. one")
             => '((1 3 markdown-marker)
                  (9 10 markdown-emphasis-marker) (10 12 markdown-emphasis) (12 13 markdown-emphasis-marker)
                  (14 15 markdown-marker) (21 23 markdown-marker))))

    (test-case "a fenced code block is monospace, its fences dimmed"
      (check (spans "```scheme\n(x)\n```\n")
             => '((1 10 markdown-marker-fence) (10 15 markdown-fence) (15 18 markdown-marker-fence))))

    (test-case "a link's label looks like a link and its address is a mark; an unsafe one is plain text"
      (check (spans "[a](https://x.org) <https://y.org> [b](javascript:alert(1))")
             => '((1 2 markdown-marker) (2 3 markdown-link) (3 19 markdown-marker)
                  (20 21 markdown-marker) (21 34 markdown-link) (34 35 markdown-marker))))

    (test-case "a task's box and a table's pipes and rule are marks"
      (check (spans "- [x] done") => '((1 2 markdown-marker) (3 6 markdown-marker)))
      (check (spans "| a |\n|---|\n| b |")
             => '((1 2 markdown-marker) (5 6 markdown-marker) (7 12 markdown-marker)
                  (13 14 markdown-marker) (17 18 markdown-marker))))

    (test-case "text with nothing to style, or half-typed Markdown, has no spans"
      (check (spans "") => '())
      (check (spans "just words") => '())
      (check (spans "**unclosed") => '())
      (check (spans "<script>alert(1)</script>") => '()))))
