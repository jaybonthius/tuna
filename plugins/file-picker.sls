#!tuna
(import (completion) (minibuffer) (files) (jobs) (ask) (layout) (commands) (keys) (buffers) (document) (views))

(define-saved file-name-history '() (lambda (v) (and (list? v) (for-all string? v))))

(define (%home) (or (getenv "HOME") "/"))

(define (%expand path)
  (let ([n (string-length path)])
    (if (and (fx> n 0) (char=? (string-ref path 0) #\~) (or (fx= n 1) (char=? (string-ref path 1) #\/)))
        (string-append (%home) (substring path 1 n))
        path)))

(define (%after-last-slash input)
  (let loop ([i (string-length input)])
    (cond
      [(fx= i 0) 0]
      [(char=? (string-ref input (fx- i 1)) #\/) i]
      [else (loop (fx- i 1))])))

(jobs:define-worker (%list-directory places emit receive)
  (import (file-picker folders))
  (let ([home (car places)] [start (cdr places)])
    (let loop ([prefix (receive)])
      (emit 'clear)
      (let ([folder (expand-path home start prefix)])
        (cond
          [(string=? prefix "") (emit (list->vector (folder-entries folder "")))]
          [(directory? folder)
           (emit (list 'base (string-length prefix)))
           (emit 'prefer-input)
           (emit (list->vector (folder-entries folder "")))]
          [else
           (let ([n (prefix-base-length home start prefix)])
             (emit (list 'base n))
             (emit (list->vector (apply append (map (lambda (dir) (folder-entries (car dir) (cdr dir)))
                                                    (partial-expansions home start n prefix))))))]))
      (emit 'done)
      (loop (receive)))))

;; A name at point lists only a folder that exists, as Cape's
;; cape-file-directory-must-exist, so the region gives way to the next
;; entry wherever a slash is no file name.
(jobs:define-worker (%list-existing-folder places emit receive)
  (import (file-picker folders))
  (let ([home (car places)] [start (cdr places)])
    (let loop ([prefix (receive)])
      (emit 'clear)
      (let ([folder (expand-path home start prefix)])
        (when (directory? folder)
          (emit (list->vector (folder-entries folder "")))))
      (emit 'done)
      (loop (receive)))))

(define read-file-name
  (case-lambda
    [(question) (read-file-name question (files:directory) file-name-history)]
    [(question directory) (read-file-name question directory file-name-history)]
    [(question directory h)
     (unless (string? directory)
       (assertion-violation 'file-picker:read-file-name "not a string" directory))
     (let* ([dir (%expand directory)]
            [dir (if (and (fx> (string-length dir) 0) (char=? (string-ref dir (fx- (string-length dir) 1)) #\/))
                     dir
                     (string-append dir "/"))])
       (%expand
         (minibuffer:call-with-setup
           (lambda (p) (minibuffer:set-input! p (files:abbreviated-path dir)))
           (lambda ()
             (completion:read-or-input question
               (list (completion:source
                       (job %list-directory (cons (%home) dir))
                       (split %after-last-slash)
                       (category completion:file-category)))
               h)))))]))

(define (%file-name-char? t)
  (and (char? t)
       (or (char-alphabetic? t) (char-numeric? t)
           (memv t '(#\- #\@ #\~ #\/ #\_ #\. #\$ #\{ #\} #\# #\% #\, #\:)))))

;; Only the slash decides, since the entry runs on the main thread after
;; every command while its session lives; the worker tests the folder.
(define (file-name-region)
  (let ([view (views:current)])
    (and view
         (let* ([b (views:buffer view)] [doc (buffers:document b)] [point (views:point view)]
                [start (let loop ([p point])
                         (if (and (fx> p 0) (%file-name-char? (document:token doc (fx- p 1)))) (loop (fx- p 1)) p))]
                [end (let loop ([p point])
                       (if (and (fx< p (document:length doc)) (%file-name-char? (document:token doc p))) (loop (fx+ p 1)) p))])
           (and (let loop ([p start])
                  (and (fx< p point) (or (eqv? (document:token doc p) #\/) (loop (fx+ p 1)))))
                (completion:fallback-region start end
                  (list (completion:source
                          (job %list-existing-folder (cons (%home) (files:directory b)))
                          (split %after-last-slash)
                          (category completion:file-category)))))))))

(commands:define-command (find-file [path (ask:file-name "Find file: ")])
  "Visits PATH and shows its buffer in the selected view."
  (layout:switch-to-buffer (files:visit path)))

(set-option! ask:file-name-reader read-file-name)
;; A candidate under a folder part that does not exist carries that
;; part, such as c/t/m's code/tuna/main.sls, which only partial matches.
(table-set! completion:category-styles completion:file-category (list completion:partial))
(keys:bind! keys:global "C-x C-f" find-file)
(keys:bind! completion:file-action-keymap "f" find-file)
