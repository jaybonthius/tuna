(import (tuna) (test) (options) (buffers) (languages) (modes) (hooks) (tables) (comment-syntax) (buffers-test))

(tables:define-table keymap "Keys.")
(hooks:define-hook hook "Setup.")
(modes:define-major-mode hashes (keymap keymap) (hook hook))
(modes:define-major-mode blocks (keymap keymap) (hook hook))
(modes:define-major-mode both (keymap keymap) (hook hook))

(languages:define-language "hashes" (mode hashes) (line-comments ("#" word-start)))
(languages:define-language "blocks" (mode blocks) (block-comments ("/*" "*/")))
(languages:define-language "both" (mode both) (line-comments ("//")) (block-comments ("/*" "*/") ("(*" "*)")))

(define (buffer-of mode)
  (let ([b (buffers:make (buffers:free-name "c") "")])
    (modes:set-major-mode mode b)
    b))

(define (delimiters b) (call-with-values (lambda () (comment-syntax:delimiters b)) list))

(test "unset, the texts are the language's first line comment, else its first block comment with its end"
  (check-equal? '("#" "") (delimiters (buffer-of hashes)))
  (check-equal? '("/*" "*/") (delimiters (buffer-of blocks)))
  (check-equal? '("//" "") (delimiters (buffer-of both))))

(test "a local start that a block comment of the language begins ends with that comment's end; a local end wins"
  (let ([b (buffer-of both)])
    (buffers:with-buffer b (options:set-local! comment-syntax:start "(*"))
    (check-equal? '("(*" "*)") (delimiters b))
    (buffers:with-buffer b (options:set-local! comment-syntax:end " */"))
    (check-equal? '("(*" " */") (delimiters b))
    (buffers:with-buffer b (options:set-local! comment-syntax:start ";"))
    (check-equal? '(";" " */") (delimiters b))
    (buffers:with-buffer b (options:unset-local! comment-syntax:end))
    (check-equal? '(";" "") (delimiters b))))

(test "the language's entries are read when asked, so a configuration's change reaches open buffers"
  (let ([b (buffer-of hashes)])
    (languages:define-language "hashes" (line-comments (";")))
    (check-equal? '(";" "") (delimiters b))
    (tables:set! languages:line-comments "hashes" '())
    (check-equal? '(#f "") (delimiters b))
    (tables:set! languages:line-comments "hashes" '("#"))
    (check-raises (buffers-test:raised-with? 'languages:line-comments-of "the entry is not a list of delimiters"
                    (list "hashes" '("#")))
                  (comment-syntax:delimiters b))
    (check-raises (buffers-test:raised? 'comment-syntax:delimiters "not a buffer") (comment-syntax:delimiters 'b))))
