(import (tuna) (test) (test-user) (web) (hooks) (options) (tables) (timers) (keys) (layout) (which-key) (which-key-test))

(keys:bind! keys:global "C-c w z" which-key-test:honk)

(define (owners procedure) (map car (definition-changes procedure)))

(define (wrapper client)
  (let ([found (test-user:elements (test-user:screen client) "which-key-screen")])
    (and (= 1 (length found)) (car found))))

(test "the plugin advises keys:press! and layout:screen"
  (let ([self (module-owner '(which-key))])
    (check (memq self (owners keys:press!)))
    (check (memq self (owners layout:screen)))))

(test "the screen is the layout's and, while the popup shows, the popup after it, in one div.which-key-screen"
  (options:set! which-key:delay 0)
  (test-user:settle)
  (let ([w (wrapper (test-user:client))])
    (check-equal? 1 (length (test-user:elements w "layout-screen")))
    (check-equal? '() (test-user:elements w "which-key")))
  (test-user:press! "C-c w")
  (let* ([w (wrapper (test-user:client))] [children (filter pair? (cdr (cdr w)))])
    (check-equal? '("layout-screen" "which-key")
                  (map (lambda (e) (test-user:element-attribute e "class")) children)))
  (test-user:press! "z")
  (options:set! which-key:delay 0.5))

(test "a client web removes takes its timer with it"
  (let ([other (test-user:open-client)])
    (test-user:press! other "C-c")
    (let ([before (length (timers:live))])
      (web:close-client! other)
      (test-user:settle)
      (check-equal? 1 (- before (length (timers:live)))))))

(test "unloading the plugin takes back its advice, its entry in web:client-removed and its timers, and its wrapper goes"
  (test-user:press! "C-c w")
  (let ([before (length (timers:live))] [entries (length (hooks:entries web:client-removed))] [self (module-owner '(which-key))])
    (unload-owner! self)
    (check-equal? '(1 1) (list (- before (length (timers:live))) (- entries (length (hooks:entries web:client-removed)))))
    (check (not (memq self (owners layout:screen))))
    (check (not (memq self (owners keys:press!)))))
  (test-user:press! "z")
  (check-equal? #f (wrapper (test-user:client)))
  (check-equal? 1 (length (test-user:elements (test-user:screen) "layout-screen")))
  (load-module! '(which-key))
  (test-user:settle)
  (check (wrapper (test-user:client))))
