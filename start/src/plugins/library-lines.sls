(library (plugins library-lines)
  (export
    library-line?
    library-line-id
    library-line-clause
    library-line-source?
    library-line-roots
    library-line-build
    library-lines-equal?
    read-library-requests
    choose-library-line
    describe-requester)
  (import (chezscheme) (only (plugins installs) install-id? commits-equal?))

  (define (string-clause? c)
    (and (fx= (length c) 2) (memq (car c) '(git commit local)) (string? (cadr c))))

  (define (root? r)
    (or (string? r) (and (pair? r) (string? (car r)) (string? (cdr r)))))

  (define (clause? c)
    (and (list? c) (pair? c)
         (or (string-clause? c)
             (and (eq? (car c) 'library-directories) (pair? (cdr c)) (for-all root? (cdr c)))
             (and (eq? (car c) 'build) (for-all string? (cdr c))))))

  ;; A Chez library form names its library with a list, so the two never
  ;; meet. A git source is always at a commit, so the configuration fixes
  ;; every library it does not leave to the plugins.
  (define (library-line? x)
    (and (list? x) (fx>= (length x) 2) (eq? (car x) 'library) (install-id? (cadr x))
         (for-all clause? (cddr x))
         (let ([keys (map car (cddr x))])
           (let loop ([keys keys])
             (or (null? keys) (and (not (memq (car keys) (cdr keys))) (loop (cdr keys))))))
         (not (and (assq 'local (cddr x)) (or (assq 'git (cddr x)) (assq 'commit (cddr x)))))
         (or (not (assq 'git (cddr x))) (assq 'commit (cddr x)))))

  (define (library-line-id line) (cadr line))

  (define (library-line-clause line key)
    (let ([c (assq key (cddr line))])
      (and c (if (memq key '(git commit local)) (cadr c) (cdr c)))))

  (define (library-line-source? line)
    (and (or (library-line-clause line 'git) (library-line-clause line 'local)) #t))

  (define (normal-root r) (if (string? r) (cons r r) r))

  (define (library-line-roots line)
    (let ([roots (library-line-clause line 'library-directories)])
      (and roots (map normal-root roots))))

  (define (library-line-build line)
    (library-line-clause line 'build))

  (define (clause-value line key)
    (if (eq? key 'library-directories) (library-line-roots line) (library-line-clause line key)))

  (define (values-equal? key a b)
    (if (and (eq? key 'commit) a b) (commits-equal? a b) (equal? a b)))

  (define (library-lines-equal? a b)
    (for-all (lambda (key) (values-equal? key (clause-value a key) (clause-value b key)))
             '(git commit local library-directories build)))

  ;; A plugin's libraries are fixed by the plugin's commit, so each of its
  ;; lines names a git source and a commit.
  (define (read-library-requests who file)
    (guard (c [(i/o-file-does-not-exist-error? c) '()])
      (call-with-input-file file
        (lambda (p)
          (let loop ([lines '()])
            (let ([form (guard (c [(lexical-violation? c) (errorf who "~a cannot be read" file)]) (read p))])
              (cond
                [(eof-object? form) (reverse lines)]
                [(and (library-line? form) (library-line-clause form 'git))
                 (loop (cons form lines))]
                [else
                 (errorf who "~a holds ~s, which is not a library line with a git source and a commit"
                   file form)])))))))

  (define (describe-requester requester)
    (cond
      [(eq? requester 'configuration) "the configuration"]
      [(eq? requester 'repl) "a line at the REPL"]
      [(eq? (car requester) 'tuna) (format "Tuna's own plugin ~a" (cdr requester))]
      [(eq? (car requester) 'test-files) (format "the test files of ~a" (cdr requester))]
      [else (format "~a ~a" (car requester) (cdr requester))]))

  (define (unique-values key values)
    (fold-right (lambda (v kept) (if (exists (lambda (k) (values-equal? key v k)) kept) kept (cons v kept)))
                '() values))

  ;; A line typed at the REPL replaces the configuration's for the session,
  ;; as a later use-plugin line does.
  (define (choose-library-line who id requests descendant)
    (let* ([repl (find (lambda (r) (eq? (cdr r) 'repl)) requests)]
           [configuration (find (lambda (r) (eq? (cdr r) 'configuration)) requests)]
           [own (or repl configuration)]
           [others (remp (lambda (r) (memq (cdr r) '(configuration repl))) requests)]
           [given (if own (cddr (car own)) '())])
      (define (agreed key)
        (let ([vs (unique-values key (map (lambda (r) (clause-value (car r) key)) others))])
          (cond
            [(null? (cdr vs)) (car vs)]
            [(eq? key 'commit)
             (or (descendant (agreed 'git) vs)
                 (errorf who "~a, and none descends from all the others; add (library ~a (commit \"...\")) to init.ss"
                   (requesters-text id key others) id))]
            [else
             (errorf who "~a; add a line (library ~a ...) with the clauses to use to init.ss"
               (requesters-text id key others) id)])))
      (when (and own (not (library-line-source? (car own))) (null? others))
        (errorf who "the line for library ~a has no source: give it a git or local clause, or let a plugin's tuna.deps name it" id))
      (let ([line
             `(library ,id
                ,@(cond
                    [(assq 'git given) => (lambda (git) (list git (assq 'commit given)))]
                    [(assq 'local given) => list]
                    [else `((git ,(agreed 'git)) ,(or (assq 'commit given) `(commit ,(agreed 'commit))))])
                ,@(filter values
                    (map (lambda (key)
                           (cond
                             [(assq key given)]
                             [(null? others) #f]
                             [else (let ([v (agreed key)]) (and v (cons key v)))]))
                         '(library-directories build))))])
        (values line
                (if own
                    (map cdr (remp (lambda (r) (library-lines-equal? (car r) line))
                                   (if (and repl configuration) (cons configuration others) others)))
                    '())))))

  (define (requesters-text id key requests)
    (if (eq? key 'commit)
        (let ([parts (map (lambda (r) (format "~a at commit ~a" (describe-requester (cdr r)) (clause-value (car r) 'commit)))
                          (cdr requests))])
          (format "~a asks for ~a at commit ~a~{, ~a~} and ~a"
            (describe-requester (cdar requests)) id (clause-value (caar requests) 'commit)
            (list-head parts (fx- (length parts) 1)) (car (last-pair parts))))
        (format "~{~a~^, ~} ask for ~a with different ~a clauses"
          (map (lambda (r) (describe-requester (cdr r))) requests) id key))))
