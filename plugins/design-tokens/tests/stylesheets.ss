(import (tuna) (test) (design-tokens-test css) (design-tokens-test token-file))

(define stylesheets
  '("design-tokens/design-tokens.css" "faces/faces.css" "views/views.css" "layout/layout.css" "layout-split/layout-split.css" "ui/ui.css"
    "layout-tabs/layout-tabs.css" "status-line/status-line.css" "completion-list/completion-list.css"
    "echo-area/echo-area.css" "minibuffer/minibuffer.css" "completion/completion.css"))

(test "every Tuna stylesheet declares the three layers first, so their order holds whichever file loads first"
  (check-equal? '()
    (filter (lambda (file) (not (equal? "@layer defaults, themes, preferences" (car (design-tokens-test/css:statements (design-tokens-test/css:file-text file))))))
            stylesheets)))

(test "no stylesheet uses !important, which would reverse the layers' order"
  (check-equal? '()
    (filter (lambda (file)
              (exists (lambda (r) (exists (lambda (d) (design-tokens-test/css:search (cdr d) "!important" 0)) (design-tokens-test/css:rule-declarations r)))
                      (design-tokens-test/css:file-rules file)))
            stylesheets)))

;; A design token must be declared; any other custom property is a
;; component token or a plugin's own, which nobody need declare, so it
;; must carry a fallback unless its own file declares it.
(test "a design token a stylesheet reads is declared, and any other custom property it reads has a fallback or is its own"
  (check-equal? '()
    (apply append
      (map (lambda (file)
             (let* ([rules (design-tokens-test/css:file-rules file)]
                    [own (apply append (map (lambda (r) (map car (design-tokens-test/css:rule-declarations r))) rules))])
               (map (lambda (r) (list file (car r)))
                    (filter (lambda (r) (not (if (design-tokens-test/css:prefix? "--tuna-" (car r))
                                                 (design-tokens-test/token-file:declared? (car r))
                                                 (or (cdr r) (member (car r) own)))))
                            (apply append (map (lambda (r) (apply append (map (lambda (d) (design-tokens-test/css:references (cdr d))) (design-tokens-test/css:rule-declarations r))))
                                               rules))))))
           stylesheets))))

;; Without the token file a declaration that reads a token with no
;; fallback is invalid as a whole, so a fallback beside it never shows. A
;; custom property's declaration draws nothing itself.
(define (bare-tokens file selector)
  (let ([r (find (lambda (r) (and (string=? "defaults" (design-tokens-test/css:rule-layer r))
                                  (member selector (map design-tokens-test/css:trim (design-tokens-test/css:split (design-tokens-test/css:rule-selector r) #\,)))))
                 (design-tokens-test/css:file-rules file))])
    (map car (filter (lambda (ref) (not (cdr ref)))
                     (apply append (map (lambda (d) (design-tokens-test/css:references (cdr d)))
                                        (filter (lambda (d) (not (design-tokens-test/css:prefix? "--" (car d)))) (design-tokens-test/css:rule-declarations r))))))))

(test "without the token file the cursor, the region and the selected view's edge still show; only other cursors need the tokens"
  (check-equal? '(("--tuna-text-muted") () () () () () ())
    (map (lambda (r) (apply bare-tokens r))
         '(("views/views.css" ".cursor") ("views/views.css" ".cursor.primary")
           ("views/views.css" ".region :not(.cursor, .view-anchor, .view-place, .above-region, .above-region *)")
           ("views/views.css" ".view .line.region-line") ("views/views.css" ".view.nowrap .line.region-line")
           ("layout/layout.css" ".layout-view:not(.locked) > .view") ("layout/layout.css" ".layout-view.selected:not(.locked)")))))

(test "so do the focus outline and a list's selected row, which ui draws; the row loses only its weight"
  (check-equal? '(() ("--tuna-font-weight-semibold"))
    (map (lambda (r) (apply bare-tokens r))
         '(("ui/ui.css" ":where(:focus-visible)") ("ui/ui.css" ".ui-list-row[aria-current=\"true\"]")))))
