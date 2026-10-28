;;; The markdown plugin's faces. A character can be several things at once
;;; (bold inside a link, a `#` marker in a heading), but a highlight gives
;;; it one face, so a face names every style a run has, in a fixed order:
;;; `markdown-strong-emphasis`, `markdown-heading-1-marker`. rules.css
;;; styles each part wherever it appears in a face's name.
prelude: :gerbil/core

(import (only-in :tuna/plugins/buffers/contract make-span span-start span-end span-value))
(export (struct-out styled)
        styled-spans)

;; The parts a face is made of, in the order its name lists them.
(def face-parts
  '(heading-1 heading-2 heading-3 heading-4 heading-5 heading-6
    strong emphasis strikethrough code link marker fence))

;; Characters START..END (from 0, end-exclusive) styled as PART, one of
;; face-parts.
(defstruct styled ((start : :fixnum) (end : :fixnum) (part : :symbol)) final: #t)

;; The face of a run styled as each of PARTS.
(def (face-of (parts : :list)) => :symbol
  (string->symbol
   (apply string-append "markdown"
          (map (lambda ((part : :symbol)) (string-append "-" (symbol->string part)))
               (filter (cut memq <> parts) face-parts)))))

;; Highlight spans for RANGES, a list of styled, at text positions OFFSET
;; plus their characters: one span for each longest run whose characters
;; have the same parts, with the face of those parts, ordered by start.
(def (styled-spans (ranges : :list) (offset : :fixnum)) => :list
  (let* ((edges (list-sort fx<
                           (let lp ((ranges ranges) (out []))
                             (match ranges
                               ([] out)
                               ([r . more]
                                (using (r : styled)
                                  (lp more (cons* r.start r.end out))))))))
         (points (let dedup ((edges edges) (out []))
                   (match edges
                     ([] (reverse out))
                     ([e . more] (dedup more (if (and (pair? out) (fx= (car out) e)) out (cons e out))))))))
    (let lp ((points points) (out []))
      (match points
        ([from to . _]
         (let (parts (filter-map (lambda ((r : styled))
                                   (and (fx<= r.start from) (fx>= r.end to) r.part))
                                 ranges))
           (if (null? parts)
             (lp (cdr points) out)
             (let ((face (face-of parts))
                   (start (fx+ from offset))
                   (end (fx+ to offset)))
               (lp (cdr points)
                   (match out
                     ;; A run touching the one before with the same face
                     ;; joins it.
                     ([previous . earlier]
                      (if (and (fx= (span-end previous) start) (eq? (span-value previous) face))
                        (cons (make-span (span-start previous) end face) earlier)
                        (cons (make-span start end face) out)))
                     (else (cons (make-span start end face) out))))))))
        (else (reverse out))))))
