#lang :tuna/prelude
;;; Stylesheet inspection, for the help plugin: M-x describe-stylesheets
;;; lists the page's stylesheets in order and checks them; M-x
;;; reload-stylesheets reads their files again. Either shows one line in
;;; the echo area when a check fails.
;;;
;;; The checks: a replacement whose owner is on but adds no stylesheet of
;;; that name (a replacement whose owner is off is dormant and not
;;; reported); a var(--x) without a fallback that no stylesheet on the page
;;; defines, found by a text scan, not a CSS parser: comments are skipped,
;;; and so are names used only inside another var()'s fallback; a
;;; definition is --x followed by a colon. A file that cannot be read is
;;; reported too.
(import :tuna/kernel
        :tuna/plugins/commands/contract
        :tuna/plugins/help/contract
        :tuna/plugins/stylesheets/contract)
(export describe-stylesheets!
        reload-stylesheets!
        stylesheet-warnings)

(def (slot-label (owner : :symbol) (name : :symbol)) => :string
  (string-append "(" (symbol->string owner) " " (symbol->string name) ")"))

;; Where PATTERN starts in CSS at or after I, or #f.
(def (search (css : :string) (pattern : :string) (i : :fixnum)) => (Maybe :fixnum)
  (let ((last (fx- (string-length css) (string-length pattern)))
        (size (string-length pattern)))
    (let loop ((at i))
      (cond
       ((fx> at last) #f)
       ((let same? ((k 0))
          (or (fx= k size)
              (and (char=? (string-ref css (fx+ at k)) (string-ref pattern k))
                   (same? (fx1+ k)))))
        at)
       (else (loop (fx1+ at)))))))

;; CSS without its /* */ comments.
(def (strip-comments (css : :string)) => :string
  (let (out (open-output-string))
    (let loop ((i 0))
      (let (start (search css "/*" i))
        (if start
          (let (end (search css "*/" (fx+ start 2)))
            (write-string (substring css i start) out)
            (when end (loop (fx+ end 2))))
          (write-string (substring css i (string-length css)) out))))
    (get-output-string out)))

(def (name-char? (c : :char)) => :boolean
  (or (char-alphabetic? c) (char-numeric? c) (char=? c #\-) (char=? c #\_)))

;; The end of the custom property name starting at I.
(def (name-end (css : :string) (i : :fixnum)) => :fixnum
  (let loop ((j i))
    (if (and (fx< j (string-length css))
             (or (name-char? (string-ref css j)) (fx> (char->integer (string-ref css j)) 127)))
      (loop (fx1+ j))
      j)))

(def (skip-space (css : :string) (i : :fixnum)) => :fixnum
  (let loop ((j i))
    (if (and (fx< j (string-length css)) (char-whitespace? (string-ref css j)))
      (loop (fx1+ j))
      j)))

;; Names CSS defines: --x followed by a colon.
(def (defined-names (css : :string)) => :list
  (let loop ((i 0) (names []))
    (let (start (search css "--" i))
      (if start
        (let* ((end (name-end css (fx+ start 2)))
               (after (skip-space css end)))
          (loop (fxmax end (fx+ start 2))
                (if (and (fx> end (fx+ start 2))
                         (fx< after (string-length css))
                         (char=? (string-ref css after) #\:)
                         (not (and (fx> start 0) (name-char? (string-ref css (fx1- start))))))
                  (cons (substring css start end) names)
                  names)))
        names))))

;; The index after the parenthesis closing the one open before I.
(def (after-closing (css : :string) (i : :fixnum)) => :fixnum
  (let loop ((j i) (depth 1))
    (cond
     ((fx>= j (string-length css)) j)
     ((char=? (string-ref css j) #\() (loop (fx1+ j) (fx1+ depth)))
     ((char=? (string-ref css j) #\)) (if (fx= depth 1) (fx1+ j) (loop (fx1+ j) (fx1- depth))))
     (else (loop (fx1+ j) depth)))))

;; Names CSS uses in var() without a fallback, outside other fallbacks.
(def (required-names (css : :string)) => :list
  (let loop ((i 0) (names []))
    (let (start (search css "var(" i))
      (cond
       ((not start) (reverse names))
       ((and (fx> start 0) (name-char? (string-ref css (fx1- start))))
        (loop (fx+ start 4) names))
       (else
        (let* ((name-start (skip-space css (fx+ start 4)))
               (end (name-end css name-start))
               (after (skip-space css end))
               (name (substring css name-start end))
               (fallback? (and (fx< after (string-length css)) (char=? (string-ref css after) #\,))))
          (loop (after-closing css (fx+ start 4))
                (if (or fallback? (not (string-prefix? "--" name)) (member name names))
                  names
                  (cons name names)))))))))

;; One line per failing check, in page order: what describe-stylesheets
;; lists under "Warnings:".
(def (stylesheet-warnings) => :list
  (let* ((sheets (page-stylesheets))
         (texts (map (lambda ((s : stylesheet))
                       (cons s (strip-comments (or (stylesheet-text s) ""))))
                     sheets))
         (defined (apply append (map (lambda ((pair : :pair)) (defined-names (cdr pair))) texts))))
    (append
     (filter-map (lambda ((s : stylesheet))
                   (let (warning (stylesheet-warning s))
                     (and warning
                          (string-append (slot-label (stylesheet-owner s) (stylesheet-name s))
                                         ": " warning))))
                 sheets)
     (filter-map (lambda ((r : stylesheet-replacement))
                   (and (eq? (stylesheet-replacement-target r) 'absent)
                        (string-append (symbol->string (stylesheet-replacement-replaced-by r))
                                       " replaces "
                                       (slot-label (stylesheet-replacement-owner r)
                                                   (stylesheet-replacement-name r))
                                       ", but " (symbol->string (stylesheet-replacement-owner r))
                                       " adds no stylesheet named "
                                       (symbol->string (stylesheet-replacement-name r)))))
                 (stylesheet-replacements))
     (apply append
       (map (lambda ((pair : :pair))
              (let (s (: (car pair) stylesheet))
                (filter-map (lambda ((name : :string))
                              (and (not (member name defined))
                                   (string-append "var(" name ") in "
                                                  (slot-label (stylesheet-owner s) (stylesheet-name s))
                                                  " has no fallback, and no stylesheet defines "
                                                  name)))
                            (required-names (cdr pair)))))
            texts)))))

(def (stylesheet-line (s : stylesheet)) => :string
  (string-append (slot-label (stylesheet-owner s) (stylesheet-name s))
                 "  " (stylesheet-path s)
                 (let (by (stylesheet-replaced-by s))
                   (if by (string-append "  replaced by " (symbol->string by)) ""))))

(def (removal-lines) => :list
  (filter-map (lambda ((r : stylesheet-replacement))
                (and (not (stylesheet-replacement-path r))
                     (eq? (stylesheet-replacement-target r) 'present)
                     (string-append (slot-label (stylesheet-replacement-owner r)
                                                (stylesheet-replacement-name r))
                                    "  removed by "
                                    (symbol->string (stylesheet-replacement-replaced-by r)))))
              (stylesheet-replacements)))

;; How many WARNINGS there are, for the echo area.
(def (warning-count (warnings : :list)) => :string
  (string-append (number->string (length warnings))
                 (if (and (pair? warnings) (null? (cdr warnings))) " warning" " warnings")))

;; List the page's stylesheets in *Help* and check them.
(def (describe-stylesheets!) => :void
  (let ((sheets (page-stylesheets))
        (removals (removal-lines))
        (warnings (stylesheet-warnings)))
    (show-help "Stylesheets"
               (append (if (null? sheets)
                         ["No stylesheets are on the page."]
                         (cons "On the page, in order:" (map stylesheet-line sheets)))
                       (if (null? removals) [] (cons "Removed:" removals))
                       (if (null? warnings) [] (cons "Warnings:" warnings))))
    (when (pair? warnings)
      (message (string-append "Stylesheets: " (warning-count warnings) "; see *Help*")))))

;; Read every stylesheet's file again and say how many changed.
(def (reload-stylesheets!) => :void
  (let* ((changed (reread-stylesheets!))
         (warnings (stylesheet-warnings)))
    (message (string-append "Stylesheets reread: " (number->string changed) " changed"
                            (if (pair? warnings)
                              (string-append "; " (warning-count warnings)
                                             ", M-x describe-stylesheets lists them")
                              "")))))
