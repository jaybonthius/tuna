;;; Every space-separated component must match; matching sees only plain text.
prelude: :gerbil/core
(import :std/text/pregexp :tuna/kernel :tuna/plugins/completion/contract)
(export orderless orderless-compile)

;; Literal wins when both styles match. Compile regexps once per input, not
;; once per candidate; invalid regexps retain the component's literal meaning.
(def (compile-component (component : :string)) => :procedure
  (let* ((sensitive? (ormap char-upper-case? (string->list component)))
         (literal (if sensitive? component (string-downcase component)))
         (regexp (with-catch (lambda (_) #f)
                   (lambda () (pregexp (if sensitive? component
                                         (string-append "(?i:" component ")")))))))
    (lambda ((text : :string))
      (let (start (string-contains (if sensitive? text (string-downcase text)) literal))
        (if start (cons start (fx+ start (string-length component)))
          (and regexp
               (let (positions (pregexp-match-positions regexp text))
                 (and positions (car positions)))))))))

;; Components are independent, so uppercase makes only that component
;; case-sensitive. The component compiler is the seam for future dispatch.
(def (orderless-compile (input : :string)) => :procedure
  (let (matchers (map compile-component
                     (filter (lambda ((part : :string)) (not (string-empty? part)))
                             (string-split input #\space))))
    (lambda ((text : :string))
      (let lp ((rest matchers) (spans []))
        (if (null? rest) (reverse spans)
          (let (span ((car rest) text))
            (and span (lp (cdr rest) (cons span spans)))))))))

(defplugin (orderless ctx)
  "Space-separated literal or regexp components, in any order, with smart case."
  requires: [completion-service]
  (context-define-completion-style! ctx
    (make-completion-style 'orderless orderless-compile
      "Each component matches literally or as a valid regexp; uppercase makes that component case-sensitive.")))
