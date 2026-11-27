#!tuna

;; rg's pace cannot be set, so these stand in for it: each prints as rg
;; does with --null, at its own pace, whatever it is asked to search.
(define (path name) (string-append (getenv "HOME") "/bin/" name))

(define (%program! name text)
  (let ([file (path name)])
    (when (file-exists? file) (delete-file file))
    (call-with-output-file file (lambda (p) (put-string p (string-append "#!/bin/sh\n" text))))
    (chmod file #o755)))

(unless (file-exists? (string-append (getenv "HOME") "/bin")) (mkdir (string-append (getenv "HOME") "/bin")))

(%program! "slow-rg" "printf './a.txt\\000%s\\n' '1:first'\nsleep 60\nprintf './a.txt\\000%s\\n' '2:second'\n")
(%program! "many-rg" "awk 'BEGIN { for (i = 1; i <= 5000; i++) printf \"./many.txt%c%d:line %d\\n\", 0, i, i }'\n")
(%program! "grouped-rg"
  "printf './a.txt\\000%s\\n' '1:one a'\nsleep 0.5\nprintf './a.txt\\000%s\\n' '2:two a'\nprintf './sub/b.txt\\000%s\\n' '1:one b'\nsleep 0.5\nprintf './sub/b.txt\\000%s\\n' '2:two b'\n")
(%program! "interleaved-rg"
  "printf './a.txt\\000%s\\n' '1:one a'\nsleep 0.3\nprintf './b.txt\\000%s\\n' '1:one b'\nsleep 0.3\nprintf './a.txt\\000%s\\n' '2:two a'\nsleep 2\n")
