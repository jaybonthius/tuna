(import (tuna) (test) (test-user) (keys) (xref))

(define displays (list (xref:definitions-display) (xref:references-display)))

(define apropos-command (keys:command-remapping (test-user:client) xref:find-apropos))

(test "loading xref-picker sets xref's displays and remaps xref:find-apropos; unloading takes them back"
  (check-equal? #f apropos-command)
  (load-module! '(xref-picker))
  (let ([set (list (xref:definitions-display) (xref:references-display))])
    (check (eq? (car set) (cadr set)))
    (check (not (memq (car set) displays)))
    (check (keys:command-remapping (test-user:client) xref:find-apropos))
    (unload-owner! (module-owner '(xref-picker)))
    (check-equal? displays (list (xref:definitions-display) (xref:references-display)))
    (check-equal? #f (keys:command-remapping (test-user:client) xref:find-apropos))))
