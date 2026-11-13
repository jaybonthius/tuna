#!tuna
(import (commands) (keys) (web))

(define-table keymaps
  "Repeating keymaps: after a command run by two or more keys, one that binds the last of them to that command stays while each next key is found in it.")

;; A quit can cut a keymap's on-exit short, so each client's newest
;; repetition is ended through the procedure that ends it, which does
;; nothing once the keymap has ended.
(define %ends (make-ephemeron-eq-hashtable))

(define (%last-key sequence)
  (let loop ([i (fx- (string-length sequence) 1)])
    (cond
      [(fx< i 0) #f]
      [(char=? (string-ref sequence i) #\space)
       (substring sequence (fx+ i 1) (string-length sequence))]
      [else (loop (fx- i 1))])))

(define (%keymap-for command key)
  (exists (lambda (entry)
            (let ([keymap (car entry)])
              (and (eq? (table-ref keymap key #f) command) keymap)))
          (table-entries keymaps)))

(define (%enter command)
  (let* ([sequence (keys:command-keys)]
         [key (and sequence (%last-key sequence))]
         [keymap (and key (%keymap-for command key))]
         [client (and keymap (web:current-client))])
    (when client
      ((eq-hashtable-ref %ends client void))
      (eq-hashtable-set! %ends client
        (keys:push-keymap! client keymap (lambda (found next) (eq? found keymap)))))))

(add-hook! commands:after-command %enter)
