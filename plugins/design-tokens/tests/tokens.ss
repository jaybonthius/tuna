(import (tuna) (test) (design-tokens-test css) (design-tokens-test colours) (design-tokens-test token-file))

(define token design-tokens-test/token-file:token)

(test "the token file declares 555 custom properties: 500 primitives, 194 of them colours, and 55 semantic tokens"
  (check-equal? '(555 500 194 55)
    (list (length design-tokens-test/token-file:tokens) (length design-tokens-test/token-file:primitives) (length design-tokens-test/token-file:colour-primitives) (length design-tokens-test/token-file:semantic-names)))
  (check (for-all design-tokens-test/token-file:declared? (map (lambda (n) (string-append "--tuna-" n)) design-tokens-test/token-file:semantic-names))))

(test "each semantic token reads primitives only, though an overlay mixes one with transparent and a fluid size reads none"
  (check-equal? '()
    (filter (lambda (n) (not (for-all (lambda (r) (assoc (car r) design-tokens-test/token-file:primitives)) (design-tokens-test/css:references (token n)))))
            design-tokens-test/token-file:semantic-names)))

(test "semantic tokens have the documented defaults"
  (check-equal? '("var(--tuna-gray-1)" "var(--tuna-gray-4)" "var(--tuna-blue-5)" "var(--tuna-gray-12)" "var(--tuna-blue-10)"
                  "var(--tuna-gray-10)" "var(--tuna-shadow-3)" "var(--tuna-ease-out-5)" "var(--tuna-duration-3)")
    (map token '("surface" "chrome" "region" "cursor" "focus" "text-faint" "shadow-raised" "ease" "duration"))))

(test "hover and pressed are overlays, which work over any background"
  (check-equal? '("color-mix(in oklch, var(--tuna-gray-12) 8%, transparent)" "color-mix(in oklch, var(--tuna-gray-12) 14%, transparent)")
    (map token '("hover" "pressed"))))

(test "bars and controls are fluid between a 320 px and a 1440 px window, with no breakpoint"
  (check-equal? '("clamp(1.75rem, 1.678571rem + 0.357143vw, 2rem)" "clamp(1.875rem, 1.839286rem + 0.178571vw, 2rem)")
    (map token '("bar-size" "control-size"))))

(test "text around buffers is Fira Sans and buffer text Fira Code, each served with the stylesheet and falling back to a stack"
  (check-equal? '("var(--tuna-font-fira-sans)" "var(--tuna-font-fira-code)" "\"Fira Sans\", var(--tuna-font-humanist)"
                  "\"Fira Code\", var(--tuna-font-monospace-code)")
    (map token '("font-ui" "font-code" "font-fira-sans" "font-fira-code"))))

(define font-faces
  (map (lambda (r)
         (let ([family (design-tokens-test/css:declaration r "font-family")] [src (design-tokens-test/css:declaration r "src")])
           (list (substring family 1 (- (string-length family) 1)) (design-tokens-test/css:declaration r "font-weight")
                 (let ([from (+ (design-tokens-test/css:search src "url(\"" 0) 5)]) (substring src from (design-tokens-test/css:search src "\"" from))))))
       (filter (lambda (r) (string=? "@font-face" (design-tokens-test/css:rule-selector r))) (design-tokens-test/css:rules design-tokens-test/token-file:text))))

(test "the @font-face rules name the fonts in the plugin's folder, each there, with its licence beside it"
  (check-equal? '(("Fira Sans" "400" "fonts/FiraSans-Regular.woff2") ("Fira Sans" "600" "fonts/FiraSans-SemiBold.woff2")
                  ("Fira Sans" "700" "fonts/FiraSans-Bold.woff2") ("Fira Code" "300 700" "fonts/FiraCode-VF.woff2"))
    font-faces)
  (check-equal? '()
    (filter (lambda (file) (not (file-exists? (design-tokens-test/css:plugin-file (string-append "design-tokens/" file)))))
            (append (map caddr font-faces) '("fonts/FiraSans-OFL.txt" "fonts/FiraCode-OFL.txt")))))

(test "each colour step is one light-dark() pair, and translucency is mixed where used"
  (check-equal? '("light-dark(oklch(55% 0.18 255), oklch(55% 0.18 255))" "light-dark(oklch(99% 0.002 260), oklch(17% 0.004 260))" "oklch(100% 0 0)")
    (map token '("blue-9" "gray-1" "white")))
  (check-equal? "0 1px 2px -1px color-mix(in oklch, var(--tuna-shadow-color) 50%, transparent),\n      0 4px 8px -3px color-mix(in oklch, var(--tuna-shadow-color) 70%, transparent)"
    (token "shadow-2")))

(test "fluid sizes and conditional radii follow the view, not the window"
  (check-equal? '("clamp(1.5rem, 6cqi, 2.5rem)" "clamp(0px, calc(100cqi - 100%) * 1e5, var(--tuna-radius-6))")
    (map token '("font-size-fluid-3" "radius-conditional-6"))))

(test "every colour is inside sRGB, so no browser clips it and changes its contrast"
  (check-equal? '()
    (filter (lambda (d)
              (exists (lambda (v) (not (for-all (lambda (x) (<= -1e-6 x (+ 1 1e-6))) (apply design-tokens-test/colours:oklch->linear v))))
                      (design-tokens-test/colours:oklch-values (cdr d))))
            design-tokens-test/token-file:colour-primitives)))

(test "every text and background pair the tokens are meant for meets its contrast in light and dark"
  (check-equal? 133 (length design-tokens-test/token-file:pairs))
  (check-equal? '()
    (fold-right
      (lambda (p acc)
        (fold-right
          (lambda (mode acc)
            (let ([r (design-tokens-test/token-file:token-contrast (car p) (cadr p) mode)])
              (if (< r (caddr p)) (cons (list (car p) (cadr p) mode r) acc) acc)))
          acc '(light dark)))
      '() design-tokens-test/token-file:pairs)))

(test "the chrome stands off the islands on it by at least 1.20:1"
  (check (for-all (lambda (mode) (>= (design-tokens-test/token-file:token-contrast "chrome" "surface" mode) 1.2)) '(light dark))))

(test "21 animations, each naming a keyframe rule of the same name shipped beside it"
  (let ([animations (filter (lambda (d) (design-tokens-test/css:prefix? "--tuna-animation-" (car d))) design-tokens-test/token-file:tokens)]
        [keyframes (design-tokens-test/css:keyframe-names design-tokens-test/token-file:text)])
    (check-equal? '(21 21) (list (length keyframes) (length animations)))
    (check-equal? '()
      (filter (lambda (d)
                (let ([name (substring (cdr d) 0 (design-tokens-test/css:search (cdr d) " " 0))])
                  (not (and (member name keyframes) (string=? name (string-append "tuna-" (substring (car d) 17 (string-length (car d)))))))))
              animations))))

(test "under prefers-reduced-motion, in preferences, every duration is 0s and every animation none"
  (check (pair? design-tokens-test/token-file:reduced))
  (check-equal? '()
    (filter (lambda (d)
              (let ([r (assoc (car d) design-tokens-test/token-file:reduced)])
                (cond
                  [(design-tokens-test/css:prefix? "--tuna-duration" (car d)) (not (and r (string=? (cdr r) "0s")))]
                  [(design-tokens-test/css:prefix? "--tuna-animation-" (car d)) (not (and r (string=? (cdr r) "none")))]
                  [else #f])))
            design-tokens-test/token-file:tokens)))

(test "light and dark come from each device's setting"
  (check (exists (lambda (r) (equal? "light dark" (design-tokens-test/css:declaration r "color-scheme"))) (design-tokens-test/css:rules design-tokens-test/token-file:text))))
