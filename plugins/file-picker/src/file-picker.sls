#!tuna
(import (completion) (minibuffer) (files) (jobs) (ask) (layout) (commands) (keys) (buffers) (document) (views) (faces)
        (only (file-picker folders) discarded-length restarted-name) (hooks) (options) (tables) (saved))

(saved:define-saved file-name-history '() (lambda (v) (and (list? v) (for-all string? v))))

(options:define-option preview-delay 0 (lambda (v) (and (real? v) (>= v 0)))
  "Seconds the selection of a recent file must rest before the file is previewed in the selected view; 0 previews at once.")

(define (%home) (or (getenv "HOME") "/"))

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

(define discarded 'file-picker.discarded)

(define (substitute-file-name name)
  (unless (string? name)
    (assertion-violation 'file-picker:substitute-file-name "not a string" name))
  (restarted-name name))

(define %file-name-prompts (make-weak-eq-hashtable))

(define (file-name-prompt? p)
  (unless (minibuffer:prompt? p)
    (assertion-violation 'file-picker:file-name-prompt? "not a prompt" p))
  (eq-hashtable-contains? %file-name-prompts p))

(buffers:define-layer %discarded (evaporate))

;; The face list draws the part as shadow inside its own face's element,
;; so a rule for file-picker.discarded alone restyles or hides it.
(define (%mark-discarded p)
  (when (file-name-prompt? p)
    (let ([start (minibuffer:input-start p)] [n (discarded-length (minibuffer:input p))])
      (buffers:set-spans! (buffers:layer (views:buffer (minibuffer:prompt-view p)) %discarded)
        start (minibuffer:input-end p)
        (if (fx> n 0) (list (list start (fx+ start n) (list (cons 'face (list discarded faces:shadow))))) '())))))

;; The prompt adds its input as typed, so a recalled entry would bring
;; back the part a ~/ or // discarded.
(define (%substitute-newest! h)
  (let ([entries (h)])
    (when (and (pair? entries) (fx> (discarded-length (car entries)) 0))
      (let ([name (substitute-file-name (car entries))])
        (saved:set! h (cons name (remove name (cdr entries))))))))

(define read-file-name
  (case-lambda
    [(question) (read-file-name question (files:directory) file-name-history)]
    [(question directory) (read-file-name question directory file-name-history)]
    [(question directory h)
     (unless (string? directory)
       (assertion-violation 'file-picker:read-file-name "not a string" directory))
     (let* ([dir (files:expanded-path directory)]
            [dir (if (and (fx> (string-length dir) 0) (char=? (string-ref dir (fx- (string-length dir) 1)) #\/))
                     dir
                     (string-append dir "/"))])
       (let ([name (minibuffer:call-with-setup
                     (lambda (p)
                       (eq-hashtable-set! %file-name-prompts p #t)
                       (minibuffer:set-input! p (files:abbreviated-path dir)))
                     (lambda ()
                       (completion:read-or-input question
                         (list (completion:source
                                 (job %list-directory (cons (%home) dir))
                                 (split %after-last-slash)
                                 (category completion:file-category)))
                         h)))])
         (when h (%substitute-newest! h))
         (files:expanded-path (substitute-file-name name) dir)))]))

(define (%file-name-char? t)
  (and (char? t)
       (or (char-alphabetic? t) (char-numeric? t)
           (memv t '(#\- #\@ #\~ #\/ #\_ #\. #\$ #\{ #\} #\# #\% #\, #\:)))))

(define (%file-name-bounds doc point)
  (values (let loop ([p point])
            (if (and (fx> p 0) (%file-name-char? (document:token doc (fx- p 1)))) (loop (fx- p 1)) p))
          (let loop ([p point])
            (if (and (fx< p (document:length doc)) (%file-name-char? (document:token doc p))) (loop (fx+ p 1)) p))))

(define (%slash-between? doc start end)
  (let loop ([p start])
    (and (fx< p end) (or (eqv? (document:token doc p) #\/) (loop (fx+ p 1))))))

;; Only the slash decides, since the entry runs on the main thread after
;; every command while its session lives; the worker tests the folder.
(define (file-name-region)
  (let ([view (views:current)])
    (and view
         (let* ([b (views:buffer view)] [doc (buffers:document b)] [point (views:point view)])
           (let-values ([(start end) (%file-name-bounds doc point)])
             (and (%slash-between? doc start point)
                  (completion:fallback-region start end
                    (list (completion:source
                            (job %list-existing-folder (cons (%home) (files:directory b)))
                            (split %after-last-slash)
                            (category completion:file-category))))))))))

;; As for the region, the disk is not read: finders run on the main
;; thread at every C-. A ~user path is left out, since only the user
;; database knows its folder.
(define (file-name-target view)
  (unless (views:view? view)
    (assertion-violation 'file-picker:file-name-target "not a view" view))
  (let* ([b (views:buffer view)] [doc (buffers:document b)])
    (let-values ([(start end) (%file-name-bounds doc (views:point view))])
      (let ([text (document:text doc start end)])
        (and (%slash-between? doc start end)
             (not (and (fx> (string-length text) 1) (char=? (string-ref text 0) #\~) (not (char=? (string-ref text 1) #\/))))
             (let ([path (files:expanded-path text (files:directory b))])
               (completion:make-target completion:file-category path (files:abbreviated-path path) start end)))))))

(commands:define-command (find-file [path (ask:file-name "Find file: ")])
  "Visits PATH and shows its buffer in the selected view."
  (layout:switch-to-buffer (files:visit path)))

(commands:define-command (find-file-other-view [path (ask:file-name "Find file in other view: ")])
  "Visits PATH and shows its buffer in another view, which it selects."
  (layout:call-with-overriding-action layout:display-in-other-view (lambda () (find-file path))))

(jobs:define-worker (%existing-files input emit receive)
  (import (file-picker folders))
  (emit (existing-files (cdr input) (car input)))
  (emit 'done)
  (let loop () (receive) (loop)))

(define (%recent-items value-of paths)
  (map (lambda (path) (vector path (files:abbreviated-path path) (value-of path))) paths))

(define (%no-line path) (cons path (cons #f #f)))

(define (%after-preview view) (void))

(define (%read-recent-file)
  (let ([recent (files:recent-files)])
    (when (null? recent)
      (error 'file-picker:find-recent-file "the list is empty"))
    (layout:call-with-display-view
      (lambda (display-view)
        (let-values ([(show end) (completion:location-preview display-view %after-preview)])
          (completion:read "Find recent file: "
            (list (completion:source
                    (job %existing-files (cons #t (%recent-items values recent)))
                    (in-order)
                    (category completion:file-category)
                    (preview (lambda (path) (show (and path (%no-line path)))) (lambda (path) (end (and path (%no-line path)))))
                    (preview-delay (preview-delay))))
            file-name-history))))))

(commands:define-command (find-recent-file [path (%read-recent-file)])
  "Visits PATH, read from files:recent-files, and shows its buffer in the selected view."
  (find-file path))

(define (recent-files display-view)
  (unless (or (not display-view) (procedure? display-view))
    (assertion-violation 'file-picker:recent-files "neither a procedure nor #f" display-view))
  (let-values ([(show end) (if display-view (completion:location-preview display-view %after-preview) (values #f #f))])
    (completion:source
      (job %existing-files (cons #f (%recent-items %no-line (remp files:buffer-visiting (files:recent-files)))))
      (in-order)
      (title "Recent files")
      (narrow #\f)
      (category completion:location-category)
      (preview show end)
      (preview-delay (preview-delay)))))

(options:set! ask:file-name-reader read-file-name)
(hooks:add! minibuffer:input-changed %mark-discarded)
;; A candidate under a folder part that does not exist carries that
;; part, such as c/t/m's code/tuna/main.sls, which only partial matches.
(tables:set! completion:category-styles completion:file-category (list completion:partial))
(keys:bind! keys:global "C-x C-f" find-file)
(keys:bind! keys:global "C-x 4 f" find-file-other-view)
(keys:bind! completion:file-action-keymap "f" find-file)
(hooks:add! completion:target-finders file-name-target -10)
