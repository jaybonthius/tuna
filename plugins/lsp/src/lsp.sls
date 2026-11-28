#!tuna
(import (jsonrpc) (projects) (files) (buffers) (document) (views) (layout) (modes) (commands) (keys) (ask) (faces)
        (completion) (xref) (diagnostics) (docs-at-point) (status-line) (syntax) (outline) (jobs) (processes) (haml)
        (json-rpc) (rename (only (chezscheme) format) (format %fmt)) (hooks) (options) (tables) (timers))

(define %self (current-owner))


(define-record-type (%server %make-server server?)
  (sealed #t)
  (fields command initialization-options configuration root ignored capabilities))

(define-enumeration %capability
  (completion hover signature-help definition declaration type-definition implementation references
   document-highlight document-symbol workspace-symbol code-action formatting range-formatting on-type-formatting rename
   diagnostics)
  %capability-set)

(define-syntax capabilities
  (lambda (x)
    (syntax-case x ()
      [(_ name ...)
       (for-all (lambda (n)
                  (and (identifier? n)
                       (memq (syntax->datum n)
                             '(completion hover signature-help definition declaration type-definition implementation
                               references document-highlight document-symbol workspace-symbol code-action formatting
                               range-formatting on-type-formatting rename diagnostics))))
                #'(name ...))
       #'(%capability-set name ...)]
      [_ (syntax-violation 'lsp:capabilities "not a capability" x)])))

(define %no-capabilities (%capability-set))

(define (%check-and-make-server command initialization-options configuration root ignored caps)
  (define who 'lsp:server)
  (unless (or (procedure? command) (and (list? command) (pair? command) (for-all string? command)))
    (assertion-violation who "neither a program and its arguments nor a procedure" command))
  (unless (or (procedure? root) (not root) (and (list? root) (for-all string? root)))
    (assertion-violation who "neither file names nor a procedure" root))
  (unless (and (enum-set? ignored) (enum-set-subset? ignored (enum-set-universe %no-capabilities)))
    (assertion-violation who "not a set of capabilities" ignored))
  (unless (or (procedure? caps) (list? caps))
    (assertion-violation who "not a JSON object" caps))
  (%make-server command initialization-options configuration root ignored caps))

(define-syntax server
  (lambda (x)
    (define (invalid c) (syntax-violation 'lsp:server "invalid clause" x c))
    (syntax-case x ()
      [(_ command clause ...)
       (let loop ([clauses #'(clause ...)] [given '()])
         (define (given-or n default) (let ([g (assq n given)]) (if g (cdr g) default)))
         (if (null? clauses)
             #`(%check-and-make-server command #,(given-or 'initialization-options #''())
                                       #,(given-or 'configuration #'#f) #,(given-or 'root #'#f)
                                       #,(given-or 'ignored-capabilities #'%no-capabilities)
                                       #,(given-or 'capabilities #''()))
             (let* ([c (car clauses)]
                    [n (syntax-case c () [(k . _) (identifier? #'k) (syntax->datum #'k)] [_ (invalid c)])])
               (when (assq n given)
                 (syntax-violation 'lsp:server "clause given twice" x c))
               (loop (cdr clauses)
                     (cons (case n
                             [(initialization-options configuration root ignored-capabilities capabilities)
                              (syntax-case c () [(_ e) (cons n #'e)] [_ (invalid c)])]
                             [else (invalid c)])
                           given)))))])))

(tables:define-table servers
  "Maps a server's name to its description, made with lsp:server.")

(tables:define-table language-servers
  "Maps a language, as modes:language names it, to the servers its buffers get: a list whose elements are each a server's name or a list of names, of which the first whose program is found serves.")

(define (%exported-name id)
  (let ([owner (owner-name (current-owner))])
    (if (member owner '((init) (repl)))
        id
        (string->symbol
          (call-with-string-output-port
            (lambda (p)
              (let loop ([parts owner])
                (display (car parts) p)
                (unless (null? (cdr parts))
                  (put-char p #\/)
                  (loop (cdr parts))))
              (put-char p #\:)
              (display id p)))))))

(define (%define-server! id description)
  (let ([name (%exported-name id)])
    (tables:set! servers name description)
    name))

(define-syntax define-server
  (lambda (x)
    (syntax-case x ()
      [(_ id command clause ...)
       (identifier? #'id)
       #'(define-public id (%define-server! 'id (server command clause ...)))]
      [_ (syntax-violation 'lsp:define-server "expected (lsp:define-server id command-expr clause ...)" x)])))

(options:define-option autoshutdown? #f boolean? "Whether a connection shuts down when its last buffer is killed.")

(options:define-option autoreconnect 3 (lambda (v) (or (boolean? v) (and (real? v) (>= v 0))))
  "Whether a connection whose server ends without being asked starts again: #t always, #f never, or a number: when it had run that many seconds.")

(options:define-option connect-timeout 30 (lambda (v) (and (real? v) (> v 0)))
  "Seconds a server has to answer initialize before it is stopped.")

(options:define-option send-process-id? #t boolean? "Whether initialize carries Tuna's process id.")

(options:define-option send-changes-delay 0.5 (lambda (v) (and (real? v) (>= v 0)))
  "Seconds without an edit before the edits so far are sent.")

(options:define-option extend-to-xref? #f boolean?
  "Whether a file outside the connection's root that xref reaches from a managed buffer is managed by the same connection.")

(options:define-option ignored-capabilities %no-capabilities
  (lambda (v) (and (enum-set? v) (enum-set-subset? v (enum-set-universe %no-capabilities))))
  "The features no connection gives, even when its server offers them.")

(options:define-option highlight-delay 0.5 (lambda (v) (and (real? v) (>= v 0)))
  "Seconds of idleness after a command before lsp:highlight runs.")

(options:define-option code-action-hint? #t boolean? "Whether lsp:code-action-hint asks the servers.")

(options:define-option report-progress? #t boolean? "Whether the status line shows servers' work in progress.")

(options:define-option on-type-formatting? #f boolean?
  "Whether typing a character a server names for on-type formatting asks it for edits, which apply only if the buffer has not changed since.")

(define-syntax confirmation
  (lambda (x)
    (syntax-case x ()
      [(_ name) (and (identifier? #'name) (memq (syntax->datum #'name) '(never unvisited always))) #''name]
      [_ (syntax-violation 'lsp:confirmation "not a confirmation" x)])))

(options:define-option confirm-edits 'unvisited (lambda (v) (memq v '(never unvisited always)))
  "When an edit from a server asks first: never, unvisited or always.")

(hooks:define-hook connected "Called with a connection once its server has answered initialize.")

(hooks:define-hook managed "Called with a buffer when a connection starts or stops managing it, with the buffer current.")

(tables:define-table request-handlers
  "Maps a method's name to the procedure of a connection and the params that answers a server's request of it.")

(tables:define-table notification-handlers
  "Maps a method's name to the procedure of a connection and the params called with a notification of it.")

(tables:define-table commands
  "Maps a command's name to a procedure of the connection and the command's arguments that runs it in place of asking the server.")

(tables:define-table keymap "Keys in buffers a connection manages.")

(tables:define-table diagnostic-keymap "Keys active where a server's diagnostic is drawn.")


(define (%ref v . keys)
  (let loop ([v v] [keys keys])
    (cond
      [(null? keys) (if (eq? v 'null) #f v)]
      [(and (list? v) (assoc (car keys) v)) => (lambda (p) (loop (cdr p) (cdr keys)))]
      [else #f])))

(define (%list v) (if (vector? v) (vector->list v) (if (list? v) v '())))

(define (%object? v) (and (list? v) (for-all (lambda (p) (and (pair? p) (string? (car p)))) v)))

(define (%merge a b)
  (fold-left
    (lambda (acc p)
      (let ([old (assoc (car p) acc)])
        (if (and old (%object? (cdr old)) (%object? (cdr p)) (pair? (cdr p)))
            (map (lambda (q) (if (eq? q old) (cons (car p) (%merge (cdr old) (cdr p))) q)) acc)
            (append (remp (lambda (q) (equal? (car q) (car p))) acc) (list p)))))
    a b))


(define (%unreserved? c)
  (or (char-alphabetic? c) (char-numeric? c) (memv c '(#\- #\_ #\. #\~ #\/))))

(define (path->uri path)
  (unless (and (string? path) (fx> (string-length path) 0) (char=? (string-ref path 0) #\/))
    (assertion-violation 'lsp:path->uri "not an absolute path" path))
  (call-with-string-output-port
    (lambda (p)
      (put-string p "file://")
      (%bytevector-for-each
        (lambda (byte)
          (let ([c (integer->char byte)])
            (if (and (fx< byte 128) (%unreserved? c))
                (put-char p c)
                (put-string p (string-append "%" (string-upcase (if (fx< byte 16) (string-append "0" (number->string byte 16)) (number->string byte 16))))))))
        (string->utf8 path)))))

(define (%bytevector-for-each f bv)
  (do ([i 0 (fx+ i 1)]) ((fx= i (bytevector-length bv))) (f (bytevector-u8-ref bv i))))

(define (uri->path uri)
  (unless (and (string? uri) (fx>= (string-length uri) 7) (string=? (substring uri 0 7) "file://"))
    (assertion-violation 'lsp:uri->path "not a file: URI" uri))
  (let* ([s (substring uri 7 (string-length uri))]
         [s (if (and (fx> (string-length s) 0) (char=? (string-ref s 0) #\/)) s
                (let loop ([i 0]) (if (or (fx= i (string-length s)) (char=? (string-ref s i) #\/)) (substring s i (string-length s)) (loop (fx+ i 1)))))])
    (let loop ([i 0] [bytes '()])
      (cond
        [(fx= i (string-length s)) (utf8->string (u8-list->bytevector (reverse bytes)))]
        [(and (char=? (string-ref s i) #\%) (fx< (fx+ i 2) (string-length s)))
         (loop (fx+ i 3) (cons (string->number (substring s (fx+ i 1) (fx+ i 3)) 16) bytes))]
        [else (loop (fx+ i 1) (append (reverse (bytevector->u8-list (string->utf8 (string (string-ref s i))))) bytes))]))))

(define (%program-found? program)
  (if (memv #\/ (string->list program))
      (file-exists? program)
      (let ([path (or (getenv "PATH") "")])
        (let loop ([dirs (%split-on path #\:)])
          (and (pair? dirs)
               (or (and (fx> (string-length (car dirs)) 0) (file-exists? (string-append (car dirs) "/" program)))
                   (loop (cdr dirs))))))))

(define (%split-on s c)
  (let loop ([i 0] [start 0] [acc '()])
    (cond
      [(fx= i (string-length s)) (reverse (cons (substring s start i) acc))]
      [(char=? (string-ref s i) c) (loop (fx+ i 1) (fx+ i 1) (cons (substring s start i) acc))]
      [else (loop (fx+ i 1) start acc)])))


(define (%unit encoding)
  (cond
    [(equal? encoding "utf-8") (document:unit bytes)]
    [(equal? encoding "utf-32") (document:unit characters)]
    [else (document:unit utf-16)]))

(define (%char-width c encoding)
  (let ([n (char->integer c)])
    (cond
      [(equal? encoding "utf-32") 1]
      [(equal? encoding "utf-8") (cond [(fx< n #x80) 1] [(fx< n #x800) 2] [(fx< n #x10000) 3] [else 4])]
      [else (if (fx< n #x10000) 1 2)])))

(define (%measure s encoding)
  (let loop ([i 0] [n 0])
    (if (fx= i (string-length s)) n (loop (fx+ i 1) (fx+ n (%char-width (string-ref s i) encoding))))))

(define (%content-start doc)
  (let ([t (document:token doc 0)]) (if (and (document:node? t) (not (document:atom? t))) 1 0)))

(define (%content-end doc)
  (let ([n (document:length doc)])
    (if (and (fx> n 0) (eq? (document:token doc (fx- n 1)) 'close)) (fx- n 1) n)))

(define (%last-line doc) (document:line doc (%content-end doc)))

(define (%line-end doc line)
  (if (fx< line (%last-line doc))
      (fx- (document:line-start doc (fx+ line 1)) 1)
      (%content-end doc)))

(define (%newlines s)
  (let loop ([i 0] [n 0] [last #f])
    (if (fx= i (string-length s))
        (values n last)
        (if (char=? (string-ref s i) #\newline) (loop (fx+ i 1) (fx+ n 1) i) (loop (fx+ i 1) n last)))))

(define (%atom-width doc q unit) (fx- (document:offset doc (fx+ q 1) unit) (document:offset doc q unit)))

(define (%position doc p encoding)
  (let* ([unit (%unit encoding)] [line (document:line doc p)] [ls (document:line-start doc line)])
    (if (fx= (document:offset doc p (document:unit atoms)) 0)
        (values (fx- line 1) (fx- (document:offset doc p unit) (document:offset doc ls unit)))
        (let ([texts (buffers:atom-texts doc 0 p)])
          (let loop ([ts texts] [extra 0] [from ls] [adjust 0])
            (if (null? ts)
                (values (fx+ (fx- line 1) extra)
                        (fx+ adjust (fx- (document:offset doc p unit) (document:offset doc from unit))))
                (let-values ([(n last) (%newlines (cdar ts))])
                  (let ([q (caar ts)])
                    (cond
                      [(fx< q ls) (loop (cdr ts) (fx+ extra n) from adjust)]
                      [(fx> n 0)
                       (loop (cdr ts) (fx+ extra n) (fx+ q 1)
                             (%measure (substring (cdar ts) (fx+ last 1) (string-length (cdar ts))) encoding))]
                      [else
                       (loop (cdr ts) extra from
                             (fx+ adjust (fx- (%measure (cdar ts) encoding) (%atom-width doc q unit))))])))))))))

(define (%clamp doc p) (fxmax (%content-start doc) (fxmin p (%content-end doc))))

(define (%position-of doc line character encoding)
  (let ([unit (%unit encoding)] [len (%content-end doc)])
    (cond
      [(fx> (fx+ line 1) (%last-line doc)) len]
      [(and (fx= (document:offset doc len (document:unit atoms)) 0))
       (let* ([ls (%clamp doc (document:line-start doc (fx+ line 1)))] [le (%line-end doc (fx+ line 1))]
              [target (fxmin (fx+ (document:offset doc ls unit) (fxmax 0 character)) (document:offset doc le unit))])
         (let loop ([t target])
           (let ([p (guard (c [(not (cancelled? c)) #f]) (document:position doc t unit))])
             (if p (%clamp doc p) (loop (fx- t 1))))))]
      [else (%position-by-walk doc line character encoding)])))

;; Atoms are counted as their texts, which may hold line breaks, so the
;; content is walked from its start.
(define (%position-by-walk doc line character encoding)
  (let* ([start (%content-start doc)] [end (%content-end doc)]
         [texts (buffers:atom-texts doc start end)])
    (let loop ([q start] [l 0] [c 0] [ts texts])
      (cond
        [(fx>= q end) end]
        [(and (fx= l line) (fx>= c character)) q]
        [(fx> l line) q]
        [else
         (let ([t (document:token doc q)])
           (cond
             [(char? t)
              (if (char=? t #\newline)
                  (if (fx= l line) q (loop (fx+ q 1) (fx+ l 1) 0 ts))
                  (loop (fx+ q 1) l (fx+ c (%char-width t encoding)) ts))]
             [(and (pair? ts) (fx= (caar ts) q))
              (let-values ([(n last) (%newlines (cdar ts))])
                (if (fx> n 0)
                    (loop (fx+ q 1) (fx+ l n) (%measure (substring (cdar ts) (fx+ last 1) (string-length (cdar ts))) encoding) (cdr ts))
                    (loop (fx+ q 1) l (fx+ c (%measure (cdar ts) encoding)) (cdr ts))))]
             [else (loop (fx+ q 1) l c ts)]))]))))

(define (%json-position line character) (list (cons "line" line) (cons "character" character)))

(define (%range-at doc start end encoding)
  (let-values ([(sl sc) (%position doc start encoding)] [(el ec) (%position doc end encoding)])
    (list (cons "start" (%json-position sl sc)) (cons "end" (%json-position el ec)))))

(define (%bounds-at doc range encoding)
  (values (%position-of doc (or (%ref range "start" "line") 0) (or (%ref range "start" "character") 0) encoding)
          (%position-of doc (or (%ref range "end" "line") 0) (or (%ref range "end" "character") 0) encoding)))


(define-record-type %conn
  (sealed #t)
  (fields rpc name root folder command (mutable title) (mutable caps) (mutable ready?) (mutable docs)
          (mutable encoding) source (mutable started-at) (mutable shutting-down?) (mutable progress)
          (mutable error) (mutable timer) description))

(define-record-type %doc
  (sealed #t)
  (fields buffer (mutable path) (mutable language) (mutable mode) (mutable opened?) (mutable sent)
          (mutable changes) (mutable full?)))

(define %connections '())

(define %by-rpc (make-eq-hashtable))

(define (%conn-of who c)
  (or (and (jsonrpc:connection? c) (eq-hashtable-ref %by-rpc c #f))
      (assertion-violation who "not a connection" c)))

(define (connection? v) (and (jsonrpc:connection? v) (eq-hashtable-ref %by-rpc v #f) #t))

(define (%live? conn) (eq? (eq-hashtable-ref %by-rpc (%conn-rpc conn) #f) conn))

(define (connections) (map %conn-rpc %connections))

(define (%doc-of conn b) (find (lambda (d) (eq? (%doc-buffer d) b)) (%conn-docs conn)))

(define (%conns-of b) (filter (lambda (conn) (%doc-of conn b)) %connections))

(define (buffer-connections b)
  (unless (buffers:buffer? b)
    (assertion-violation 'lsp:buffer-connections "not a buffer" b))
  (map %conn-rpc (%ordered-conns b)))

(define (%ordered-conns b)
  (let* ([conns (%conns-of b)] [names (%wanted-order b)])
    (append (filter (lambda (n) n) (map (lambda (name) (find (lambda (c) (eq? (%conn-name c) name)) conns)) names))
            (remp (lambda (c) (memq (%conn-name c) names)) conns))))

(define (%wanted-order b)
  (let* ([mode (modes:major-mode b)] [language (modes:language mode)]
         [spec (and language (tables:ref language-servers language #f))])
    (if (list? spec) (apply append (map (lambda (e) (if (list? e) e (list e))) spec)) '())))

(define (connection-server c) (%conn-name (%conn-of 'lsp:connection-server c)))
(define (connection-root c) (%conn-root (%conn-of 'lsp:connection-root c)))
(define (connection-command c) (%conn-command (%conn-of 'lsp:connection-command c)))
(define (connection-title c) (%conn-title (%conn-of 'lsp:connection-title c)))

(define (connection-capability c . keys)
  (apply %ref (%conn-caps (%conn-of 'lsp:connection-capability c)) keys))

(define (%offers? conn feature b)
  (and (%conn-ready? conn)
       (not (enum-set-member? feature (%server-ignored (%conn-description conn))))
       (not (enum-set-member? feature (if b (buffers:with-buffer b (ignored-capabilities)) (ignored-capabilities))))
       (let ([caps (%conn-caps conn)])
         (define (on? key) (let ([v (%ref caps key)]) (and v (not (eq? v #f)))))
         (case feature
           [(completion) (on? "completionProvider")]
           [(hover) (on? "hoverProvider")]
           [(signature-help) (on? "signatureHelpProvider")]
           [(definition) (on? "definitionProvider")]
           [(declaration) (on? "declarationProvider")]
           [(type-definition) (on? "typeDefinitionProvider")]
           [(implementation) (on? "implementationProvider")]
           [(references) (on? "referencesProvider")]
           [(document-highlight) (on? "documentHighlightProvider")]
           [(document-symbol) (on? "documentSymbolProvider")]
           [(workspace-symbol) (on? "workspaceSymbolProvider")]
           [(code-action) (on? "codeActionProvider")]
           [(formatting) (on? "documentFormattingProvider")]
           [(range-formatting) (on? "documentRangeFormattingProvider")]
           [(on-type-formatting) (on? "documentOnTypeFormattingProvider")]
           [(rename) (on? "renameProvider")]
           [(diagnostics) #t]
           [else #f]))))

(define (%give conns feature b) (filter (lambda (conn) (%offers? conn feature b)) conns))


(define %reported (make-weak-eq-hashtable))

;; Mode hooks run again after each module loads, so each complaint is
;; made once per buffer.
(define (%report-once! b key message)
  (let ([seen (eq-hashtable-ref %reported b '())])
    (unless (member key seen)
      (eq-hashtable-set! %reported b (cons key seen))
      (ask:message message))))

(define (%command-of description root)
  (let ([command (%server-command description)])
    (if (procedure? command) (command root) command)))

(define (%root-of description path)
  (let* ([folder (%folder-of path)] [root (%server-root description)])
    (or (cond
          [(procedure? root) (root folder)]
          [(pair? root) (exists (lambda (name) (projects:find-marked folder (list name))) root)]
          [else #f])
        (let ([project (projects:find folder)]) (and project (projects:root project))))))

(define (%folder-of path)
  (let loop ([i (fx- (string-length path) 1)])
    (if (char=? (string-ref path i) #\/) (substring path 0 (fx+ i 1)) (loop (fx- i 1)))))

(define (%with-slash folder)
  (if (char=? (string-ref folder (fx- (string-length folder) 1)) #\/) folder (string-append folder "/")))

(define %getpid (begin (load-shared-object #f) (foreign-procedure "getpid" () int)))

(define (client-capabilities c)
  (let ([conn (%conn-of 'lsp:client-capabilities c)])
    (%client-capabilities (%conn-description conn))))

(define (%client-capabilities description)
  (let ([extra (%server-capabilities description)])
    (%merge
      `(("general" ("positionEncodings" . #("utf-32" "utf-8" "utf-16")))
        ("workspace"
         ("applyEdit" . #t)
         ("workspaceEdit" ("documentChanges" . #t) ("resourceOperations" . #("create" "rename" "delete")))
         ("configuration" . #t)
         ("workspaceFolders" . #t)
         ("symbol" ("dynamicRegistration" . #f))
         ("executeCommand" ("dynamicRegistration" . #f))
         ("didChangeConfiguration" ("dynamicRegistration" . #f))
         ("diagnostics" ("refreshSupport" . #f)))
        ("textDocument"
         ("synchronization" ("dynamicRegistration" . #f) ("willSave" . #t) ("willSaveWaitUntil" . #t) ("didSave" . #t))
         ("completion" ("dynamicRegistration" . #f)
          ("completionItem" ("snippetSupport" . #f) ("deprecatedSupport" . #t)
           ("resolveSupport" ("properties" . #("documentation" "details" "additionalTextEdits")))
           ("tagSupport" ("valueSet" . #(1))) ("insertReplaceSupport" . #f))
          ("contextSupport" . #t))
         ("hover" ("dynamicRegistration" . #f) ("contentFormat" . #("markdown" "plaintext")))
         ("signatureHelp" ("dynamicRegistration" . #f)
          ("signatureInformation" ("parameterInformation" ("labelOffsetSupport" . #t))
           ("documentationFormat" . #("markdown" "plaintext")) ("activeParameterSupport" . #t)))
         ("references" ("dynamicRegistration" . #f))
         ("definition" ("dynamicRegistration" . #f) ("linkSupport" . #t))
         ("declaration" ("dynamicRegistration" . #f) ("linkSupport" . #t))
         ("implementation" ("dynamicRegistration" . #f) ("linkSupport" . #t))
         ("typeDefinition" ("dynamicRegistration" . #f) ("linkSupport" . #t))
         ("documentHighlight" ("dynamicRegistration" . #f))
         ("documentSymbol" ("dynamicRegistration" . #f) ("hierarchicalDocumentSymbolSupport" . #t))
         ("codeAction" ("dynamicRegistration" . #f) ("resolveSupport" ("properties" . #("edit" "command")))
          ("dataSupport" . #t) ("isPreferredSupport" . #t)
          ("codeActionLiteralSupport"
           ("codeActionKind" ("valueSet" . #("quickfix" "refactor" "refactor.extract" "refactor.inline"
                                             "refactor.rewrite" "source" "source.organizeImports")))))
         ("formatting" ("dynamicRegistration" . #f))
         ("rangeFormatting" ("dynamicRegistration" . #f))
         ("onTypeFormatting" ("dynamicRegistration" . #f))
         ("rename" ("dynamicRegistration" . #f) ("prepareSupport" . #t))
         ("publishDiagnostics" ("relatedInformation" . #f) ("versionSupport" . #t) ("codeDescriptionSupport" . #f)
          ("tagSupport" ("valueSet" . #(1 2))))
         ("diagnostic" ("dynamicRegistration" . #f) ("relatedDocumentSupport" . #f)))
        ("window" ("showDocument" ("support" . #t)) ("workDoneProgress" . #t)
         ("showMessage" ("messageActionItem" ("additionalPropertiesSupport" . #f)))))
      (if (procedure? extra) '() extra))))

(define (%start! name description root folder)
  (let* ([command (%command-of description root)]
         [source (call-as-owner %self (lambda () (diagnostics:make-source)))]
         [rpc (call-as-owner %self
                (lambda ()
                  (jsonrpc:start (symbol->string name) command
                    (jsonrpc:handlers
                      [request %on-request]
                      [notification %on-notification]
                      [cancel (lambda (rpc id) (jsonrpc:notify rpc "$/cancelRequest" (list (cons "id" id))))]
                      [exit %on-exit])
                    (processes:options [directory folder]))))]
         [conn (make-%conn rpc name root folder command (%program-name command) '() #f '() "utf-16" source (real-time) #f #f #f #f
                           description)])
    (eq-hashtable-set! %by-rpc rpc conn)
    (set! %connections (append %connections (list conn)))
    (call-as-owner %self (lambda () (spawn-task (lambda (restore) (%initialize! conn)))))
    conn))

(define (%program-name command)
  (let ([p (car command)])
    (let loop ([i (fx- (string-length p) 1)])
      (cond [(fx< i 0) p] [(char=? (string-ref p i) #\/) (substring p (fx+ i 1) (string-length p))] [else (loop (fx- i 1))]))))

(define (%initialize! conn)
  (let* ([description (%conn-description conn)] [root (%conn-root conn)]
         [options (let ([o (%server-initialization-options description)]) (if (procedure? o) (o root) o))])
    (guard (c [(not (cancelled? c))
               (%conn-error-set! conn (%condition-text c))
               (report c)
               (when (jsonrpc:running? (%conn-rpc conn)) (jsonrpc:stop! (%conn-rpc conn)))])
      (let ([result (jsonrpc:request (%conn-rpc conn) "initialize"
                      `(("processId" . ,(if (send-process-id?) (%getpid) 'null))
                        ("clientInfo" ("name" . "Tuna"))
                        ("rootPath" . ,(or root 'null))
                        ("rootUri" . ,(if root (path->uri root) 'null))
                        ("workspaceFolders" . ,(%workspace-folders root))
                        ("capabilities" . ,(%client-capabilities description))
                        ("initializationOptions" . ,options))
                      (connect-timeout))])
        (%conn-caps-set! conn (or (%ref result "capabilities") '()))
        (let ([name (%ref result "serverInfo" "name")]) (when (string? name) (%conn-title-set! conn name)))
        (%conn-encoding-set! conn (or (%ref result "capabilities" "positionEncoding") "utf-16"))
        (jsonrpc:notify (%conn-rpc conn) "initialized" '())
        (%send-configuration! conn)
        (%conn-ready?-set! conn #t)
        (for-each (lambda (d) (when (buffers:live? (%doc-buffer d)) (%open! conn d))) (%conn-docs conn))
        (connected (%conn-rpc conn))))))

(define (%workspace-folders root)
  (if root (vector (list (cons "uri" (path->uri root)) (cons "name" root))) 'null))

(define (%condition-text c)
  (if (message-condition? c) (condition-message c) (%fmt "~a" c)))

(define (%configuration-of description folder)
  (let ([c (%server-configuration description)]) (if (procedure? c) (c folder) c)))

(define (%send-configuration! conn)
  (jsonrpc:notify (%conn-rpc conn) "workspace/didChangeConfiguration"
    (list (cons "settings" (or (%configuration-of (tables:ref servers (%conn-name conn) (%conn-description conn)) (%conn-root conn)) '())))))


(define (%language-id b) (modes:language (modes:major-mode b)))

(define (%text b) (let ([doc (buffers:document b)]) (buffers:text-between doc 0 (document:length doc))))

(define (%open! conn d)
  (let ([b (%doc-buffer d)])
    (%doc-opened?-set! d #t)
    (%doc-changes-set! d '())
    (%doc-sent-set! d (buffers:version b))
    (jsonrpc:notify (%conn-rpc conn) "textDocument/didOpen"
      `(("textDocument" ("uri" . ,(path->uri (%doc-path d))) ("languageId" . ,(%doc-language d))
                        ("version" . ,(buffers:version b)) ("text" . ,(%text b)))))
    (%pull-diagnostics! conn d (buffers:version b))))

(define (%close! conn d)
  (when (and (%doc-opened? d) (jsonrpc:running? (%conn-rpc conn)) (%conn-ready? conn))
    (%flush! conn)
    (jsonrpc:notify (%conn-rpc conn) "textDocument/didClose" `(("textDocument" ("uri" . ,(path->uri (%doc-path d)))))))
  (%doc-opened?-set! d #f))

(define (%manage! conn b path)
  (let ([d (make-%doc b path (%language-id b) (modes:major-mode b) #f (buffers:version b) '() #f)]
        [first? (null? (%conns-of b))])
    (%conn-docs-set! conn (append (%conn-docs conn) (list d)))
    (%set-up-buffer! b first?)
    (when (%conn-ready? conn) (%open! conn d))
    (%add-doc-entries! conn b)
    (buffers:with-buffer b (managed b))))

(define (%release! conn b)
  (let ([d (%doc-of conn b)])
    (when d
      (%close! conn d)
      (%remove-doc-entries! conn b)
      (%conn-docs-set! conn (remq d (%conn-docs conn)))
      (diagnostics:clear! (%conn-source conn) b)
      (when (null? (%conns-of b)) (%tear-down-buffer! b))
      (when (buffers:live? b) (buffers:with-buffer b (managed b))))))

(modes:define-minor-mode managed?
  "Whether a language server manages the buffer, or the current buffer when none is given."
  (state args
    (let ([b (if (null? args) (buffers:current) (car args))])
      (and b (buffers:buffer? b) (pair? (%conns-of b)) #t)))
  (keymap keymap))

;; The local values and entries a managed buffer has, set as the plugin's
;; own changes, so they go when the buffer is managed no longer.
(define (%set-up-buffer! b first?)
  (when first?
    (call-as-owner %self
      (lambda ()
        (buffers:with-buffer b
          (options:set-local! diagnostics:mode #t docs-at-point:strategy docs-at-point:all xref:prompt-for-identifier #f)
          (hooks:add-local! buffers:after-edit %after-edit)
          (hooks:add-local! completion:find-region completion-region)
          (hooks:add-local! xref:backends xref-backend)
          (hooks:add-local! docs-at-point:sources code-action-hint 80))))))

(define (%tear-down-buffer! b)
  (when (buffers:live? b)
    (call-as-owner %self
      (lambda ()
        (buffers:with-buffer b
          (options:unset-local! diagnostics:mode docs-at-point:strategy xref:prompt-for-identifier)
          (hooks:remove-local! buffers:after-edit %after-edit)
          (hooks:remove-local! completion:find-region completion-region)
          (hooks:remove-local! xref:backends xref-backend)
          (hooks:remove-local! docs-at-point:sources code-action-hint))))))

(define (%find-conn name root)
  (find (lambda (c) (and (eq? (%conn-name c) name) (equal? (%conn-root c) root) (not (%conn-shutting-down? c)))) %connections))

(define (%resolve b element)
  (let loop ([names (if (list? element) element (list element))])
    (cond
      [(null? names)
       (%report-once! b (cons 'not-found element)
         (%fmt "lsp: no server of ~a is installed" (if (list? element) element (list element))))
       #f]
      [else
       (let* ([name (car names)] [description (tables:ref servers name #f)])
         (cond
           [(not description)
            (%report-once! b (cons 'no-server name) (%fmt "lsp: no server is defined as ~a" name))
            (loop (cdr names))]
           [(let ([command (%server-command description)]) (or (procedure? command) (%program-found? (car command))))
            name]
           [else (loop (cdr names))]))])))

(define %xref-reached (make-hashtable string-hash string=?))

(define (%ensurable)
  (let ([b (buffers:current)])
    (and b (files:path b) (not (files:temporary? b)) b)))

(define %undrawn (make-weak-eq-hashtable))

(define (%drawn? b) (exists (lambda (v) (pair? (views:drawn-ranges v))) (views:showing b)))

;; Restoring a session visits many files no one looks at, and each would
;; start or join a server, so a buffer waits until a view draws it.
(define (ensure)
  (let ([b (%ensurable)])
    (when b
      (if (%drawn? b)
          (%ensure! b)
          (eq-hashtable-set! %undrawn b (modes:major-mode b))))))

(define (ensure-now)
  (let ([b (%ensurable)])
    (when b (%ensure! b))))

;; The hook also tells of a view that stopped drawing the buffer, and the
;; buffer may have changed mode since it was asked for.
(define (%ensure-when-drawn view b)
  (let ([mode (eq-hashtable-ref %undrawn b #f)])
    (when (and mode (memq view (views:showing b)) (pair? (views:drawn-ranges view)))
      (if (eq? mode (modes:major-mode b))
          (%ensure! b)
          (eq-hashtable-delete! %undrawn b)))))

(define (%ensure! b)
  (eq-hashtable-delete! %undrawn b)
  (let* ([path (files:path b)] [mode (modes:major-mode b)] [language (modes:language mode)]
         [spec (and language (tables:ref language-servers language #f))])
    (cond
      [(not language)
       (%report-once! b 'no-language (%fmt "lsp: ~a has no language" mode))
       (%release-all! b '())]
      [(not spec)
       (%report-once! b (cons 'no-entry language) (%fmt "lsp: no servers are listed for ~a" language))
       (%release-all! b '())]
      [else
       (let ([wanted (filter values (map (lambda (e) (%resolve b e)) spec))])
         (for-each
           (lambda (conn)
             (let ([d (%doc-of conn b)])
               (when (or (not (memq (%conn-name conn) wanted))
                         (not (eq? (%doc-mode d) mode))
                         (not (equal? (%doc-path d) path)))
                 (%release! conn b))))
           (%conns-of b))
         (for-each
           (lambda (name)
             (let* ([description (tables:ref servers name #f)]
                    [reached (and (extend-to-xref?) (hashtable-ref %xref-reached path #f))]
                    [root (let ([r (%root-of description path)]) (and r (%with-slash r)))]
                    [conn (or (and reached (%conn-name reached) (eq? (%conn-name reached) name)
                                   (memq reached %connections) reached)
                              (%find-conn name root)
                              (%start! name description root (or root (%folder-of path))))])
               (unless (%doc-of conn b) (%manage! conn b path))))
           wanted))])))

(define (%release-all! b keep)
  (for-each (lambda (conn) (unless (memq conn keep) (%release! conn b))) (%conns-of b)))


;; The text before an edit's start is the same before and after it, so
;; the start is counted on the content after; the end follows from the
;; removed text.
(define (%after-edit b edit)
  (when (buffers:edit-moves? edit)
    (let* ([doc (buffers:document b)] [start (buffers:edit-start edit)]
           [removed (buffers:piece-text (buffers:edit-removed edit))]
           [inserted (buffers:piece-text (buffers:edit-inserted edit))])
      (for-each
        (lambda (conn)
          (let ([d (%doc-of conn b)])
            (when (and d (%doc-opened? d))
              (if (%full-sync? conn)
                  (%doc-full?-set! d #t)
                  (let-values ([(line character) (%position doc start (%conn-encoding conn))])
                    (let-values ([(n last) (%newlines removed)])
                      (let ([end-line (fx+ line n)]
                            [end-character (if (fx> n 0)
                                               (%measure (substring removed (fx+ last 1) (string-length removed)) (%conn-encoding conn))
                                               (fx+ character (%measure removed (%conn-encoding conn))))])
                        (%doc-changes-set! d
                          (cons `(("range" ("start" . ,(%json-position line character)) ("end" . ,(%json-position end-line end-character)))
                                  ("text" . ,inserted))
                                (%doc-changes d)))))))
              (%schedule-flush! conn))))
        (%conns-of b))
      (unless (%server-edits?) (%on-type-format! b edit inserted)))))

(define (%full-sync? conn)
  (let ([sync (%ref (%conn-caps conn) "textDocumentSync")])
    (eqv? (if (pair? sync) (%ref sync "change") sync) 1)))

(define (%schedule-flush! conn)
  (when (%conn-timer conn) (timers:cancel! (%conn-timer conn)))
  (%conn-timer-set! conn
    (call-as-owner %self
      (lambda ()
        (timers:run-after (send-changes-delay) (lambda () (%conn-timer-set! conn #f) (%flush! conn)))))))

(define (%flush! conn)
  (when (%conn-timer conn)
    (timers:cancel! (%conn-timer conn))
    (%conn-timer-set! conn #f))
  (when (and (%conn-ready? conn) (jsonrpc:running? (%conn-rpc conn)))
    (let ([changed (filter values (map (lambda (d) (and (%send-changes! conn d) d)) (%conn-docs conn)))])
      ;; No server yet sends the documents a change affects, so the others
      ;; open on it are asked again, as Eglot does.
      (unless (null? changed)
        (for-each
          (lambda (d)
            (when (and (%doc-opened? d) (buffers:live? (%doc-buffer d)) (not (memq d changed)))
              (%pull-diagnostics! conn d (%doc-sent d))))
          (%conn-docs conn))))))

(define (%send-changes! conn d)
  (let ([b (%doc-buffer d)])
    (and (%doc-opened? d) (buffers:live? b) (not (eqv? (%doc-sent d) (buffers:version b)))
         (let ([changes (if (%doc-full? d) (list (list (cons "text" (%text b)))) (reverse (%doc-changes d)))]
               [version (buffers:version b)])
           (%doc-changes-set! d '())
           (%doc-full?-set! d #f)
           (%doc-sent-set! d version)
           (and (pair? changes)
                (begin
                  (jsonrpc:notify (%conn-rpc conn) "textDocument/didChange"
                    `(("textDocument" ("uri" . ,(path->uri (%doc-path d))) ("version" . ,version))
                      ("contentChanges" . ,(list->vector changes))))
                  (%pull-diagnostics! conn d version)
                  #t))))))

(define (request c method params)
  (let ([conn (%conn-of 'lsp:request c)])
    (%flush! conn)
    (jsonrpc:request (%conn-rpc conn) method params)))

(define (notify c method params)
  (let ([conn (%conn-of 'lsp:notify c)])
    (%flush! conn)
    (jsonrpc:notify (%conn-rpc conn) method params)))

(define (%doc-identifier conn b)
  (list (cons "uri" (path->uri (files:path b)))))

(define (%point-params conn b p)
  (let-values ([(line character) (%position (buffers:document b) p (%conn-encoding conn))])
    `(("textDocument" . ,(%doc-identifier conn b)) ("position" . ,(%json-position line character)))))

(define (range c b start end)
  (let ([conn (%conn-of 'lsp:range c)])
    (%range-at (buffers:document b) start end (%conn-encoding conn))))

(define (range-bounds c b r version)
  (let* ([conn (%conn-of 'lsp:range-bounds c)] [doc (buffers:document-at b version)])
    (unless doc
      (assertion-violation 'lsp:range-bounds "the buffer's log no longer holds the version" version))
    (%bounds-at doc r (%conn-encoding conn))))

(define (%bounds-now conn b r version)
  (let ([doc (buffers:document-at b version)])
    (and doc
         (let-values ([(s e) (%bounds-at doc r (%conn-encoding conn))])
           (if (fx= version (buffers:version b))
               (cons s e)
               (cons (buffers:map-position-after b s version) (buffers:map-position b e version)))))))


(jobs:define-worker (%read-lines wanted emit)
  (emit
    (map (lambda (entry)
           (let ([path (car entry)] [lines (cdr entry)])
             (cons path
                   (guard (c [#t '()])
                     (call-with-input-file path
                       (lambda (p)
                         (let loop ([n 0] [acc '()])
                           (if (> n (apply max -1 lines))
                               (reverse acc)
                               (let ([line (get-line p)])
                                 (if (eof-object? line)
                                     (reverse acc)
                                     (loop (+ n 1) (if (memv n lines) (cons (cons n line) acc) acc))))))))))))
         wanted)))

(define (%file-lines wanted)
  (if (null? wanted)
      '()
      (suspend
        (lambda (resume)
          (let ([got '()])
            (call-as-owner %self
              (lambda ()
                (jobs:start %read-lines wanted
                  (lambda (v) (set! got v))
                  (lambda (ended) (resume (lambda () got)))))))))))

(define (%character-column text character encoding)
  (let loop ([i 0] [n 0])
    (if (or (fx= i (string-length text)) (fx>= n character))
        i
        (loop (fx+ i 1) (fx+ n (%char-width (string-ref text i) encoding))))))


(define (%severity n)
  (case n [(2) (diagnostics:severity warning)] [(3) (diagnostics:severity info)] [(4) (diagnostics:severity hint)]
        [else (diagnostics:severity error)]))

(define (%details conn d)
  (let* ([tags (%list (%ref d "tags"))] [code (%ref d "code")]
         [origin (or (%ref d "source") (%conn-title conn))]
         [code (and code (if (string? code) code (number->string code)))])
    (cond
      [(and (memv 1 tags) (memv 2 tags))
       (diagnostics:details [origin origin] [code code] [tags (diagnostics:tags unnecessary deprecated)] [keymap diagnostic-keymap] [data d])]
      [(memv 1 tags)
       (diagnostics:details [origin origin] [code code] [tags (diagnostics:tags unnecessary)] [keymap diagnostic-keymap] [data d])]
      [(memv 2 tags)
       (diagnostics:details [origin origin] [code code] [tags (diagnostics:tags deprecated)] [keymap diagnostic-keymap] [data d])]
      [else (diagnostics:details [origin origin] [code code] [keymap diagnostic-keymap] [data d])])))

(define (%message d) (let ([m (%ref d "message")]) (if (string? m) m "")))

(define (%report-diagnostics! conn path version items)
  (let* ([b (files:buffer-visiting path)] [d (and b (%doc-of conn b))])
    (cond
      [(not (%offers? conn 'diagnostics (and d b))) (void)]
      [(and d (%doc-opened? d))
       (let* ([v (or version (%doc-sent d))] [doc (and (fx<= v (buffers:version b)) (buffers:document-at b v))])
         (when doc
           (diagnostics:report! (%conn-source conn) b
             (map (lambda (item)
                    (let-values ([(s e) (%bounds-at doc (%ref item "range") (%conn-encoding conn))])
                      (diagnostics:make-diagnostic s (fxmax s e) (%severity (%ref item "severity")) (%message item)
                        (%details conn item))))
                  items)
             v)))]
      [else
       (spawn-task
         (lambda (restore)
           (let* ([lines (apply append (map (lambda (item) (list (or (%ref item "range" "start" "line") 0) (or (%ref item "range" "end" "line") 0))) items))]
                  [read (%file-lines (list (cons path lines)))]
                  [texts (if (pair? read) (cdar read) '())])
             (define (pair-of position)
               (let* ([line (or (%ref position "line") 0)] [text (cdr (or (assv line texts) (cons line "")))])
                 (cons (fx+ line 1) (%character-column text (or (%ref position "character") 0) (%conn-encoding conn)))))
             (diagnostics:report! (%conn-source conn) path
               (map (lambda (item)
                      (let ([start (pair-of (%ref item "range" "start"))] [end (pair-of (%ref item "range" "end"))])
                        (diagnostics:make-diagnostic start (if (equal? start end) #f end) (%severity (%ref item "severity"))
                          (%message item) (%details conn item))))
                    items)))))])))

(define (%on-publish conn params)
  (let ([uri (%ref params "uri")])
    (when (and (string? uri) (fx>= (string-length uri) 7) (string=? (substring uri 0 7) "file://"))
      (%report-diagnostics! conn (uri->path uri) (%ref params "version") (%list (%ref params "diagnostics"))))))

(define (%pull-diagnostics! conn d version)
  (when (and (%ref (%conn-caps conn) "diagnosticProvider") (%offers? conn 'diagnostics (%doc-buffer d)))
    (let ([b (%doc-buffer d)] [path (%doc-path d)])
      (jsonrpc:request-async (%conn-rpc conn) "textDocument/diagnostic"
        `(("textDocument" ("uri" . ,(path->uri path))))
        (lambda (result)
          (when (and (buffers:live? b) (equal? (%ref result "kind") "full"))
            (%report-diagnostics! conn path version (%list (%ref result "items")))))
        (lambda (c) (void))))))


(define (%on-request rpc method params)
  (let ([conn (eq-hashtable-ref %by-rpc rpc #f)] [handler (tables:ref request-handlers method #f)])
    (if (and conn handler)
        (handler rpc params)
        (raise (make-json-rpc-error json-rpc-method-not-found-code (string-append "method not found: " method))))))

(define (%on-notification rpc method params)
  (let ([conn (eq-hashtable-ref %by-rpc rpc #f)] [handler (tables:ref notification-handlers method #f)])
    (when (and conn handler) (handler rpc params))))

(define (%configuration-request rpc params)
  (let* ([conn (eq-hashtable-ref %by-rpc rpc #f)]
         [description (tables:ref servers (%conn-name conn) (%conn-description conn))])
    (list->vector
      (map (lambda (item)
             (let* ([scope (%ref item "scopeUri")]
                    [folder (if (string? scope) (guard (c [(not (cancelled? c)) (%conn-root conn)]) (uri->path scope)) (%conn-root conn))]
                    [settings (or (%configuration-of description folder) '())]
                    [section (%ref item "section")])
               (if (string? section)
                   (let ([v (apply %ref settings (%split-on section #\.))]) (if (or (not v) (eq? v #f)) 'null v))
                   settings)))
           (%list (%ref params "items"))))))

(define (%titled-message rpc params)
  (%fmt "~a: ~a" (%conn-title (eq-hashtable-ref %by-rpc rpc #f)) (or (%ref params "message") "")))

(define (%show-message-request rpc params)
  (let ([actions (%list (%ref params "actions"))] [message (%titled-message rpc params)])
    (if (null? actions)
        (begin (ask:message message) 'null)
        (ask:choice (string-append message " ")
          (map (lambda (a) (cons (or (%ref a "title") "") a)) actions)))))

(define (%show-document rpc params)
  (let ([uri (%ref params "uri")])
    (if (and (string? uri) (fx>= (string-length uri) 7) (string=? (substring uri 0 7) "file://"))
        (let ([b (files:visit (uri->path uri))])
          (layout:switch-to-buffer b)
          '(("success" . #t)))
        '(("success" . #f)))))

(define (%apply-edit-request rpc params)
  (let ([conn (eq-hashtable-ref %by-rpc rpc #f)])
    (guard (c [(not (cancelled? c))
               `(("applied" . #f) ("failureReason" . ,(%condition-text c)))])
      (%apply-workspace-edit! conn (%ref params "edit") #f)
      '(("applied" . #t)))))

(define (%progress rpc params)
  (let ([conn (eq-hashtable-ref %by-rpc rpc #f)] [value (%ref params "value")])
    (when conn
      (case (and value (string->symbol (or (%ref value "kind") "")))
        [(begin) (%conn-progress-set! conn (list (or (%ref value "title") "") (%ref value "percentage")))]
        [(report) (when (%conn-progress conn)
                    (%conn-progress-set! conn (list (car (%conn-progress conn)) (%ref value "percentage"))))]
        [(end) (%conn-progress-set! conn #f)]
        [else (void)]))))

(define (%nothing rpc params) 'null)

(define (%on-exit rpc status)
  (let ([conn (eq-hashtable-ref %by-rpc rpc #f)])
    (when conn
      (let ([docs (%conn-docs conn)] [asked? (%conn-shutting-down? conn)]
            [ran (/ (- (real-time) (%conn-started-at conn)) 1000.0)])
        (set! %connections (remq conn %connections))
        (eq-hashtable-delete! %by-rpc rpc)
        (for-each (lambda (d) (let ([b (%doc-buffer d)]) (when (buffers:live? b) (%remove-doc-entries! conn b)))) docs)
        (diagnostics:clear! (%conn-source conn))
        (for-each (lambda (d) (let ([b (%doc-buffer d)]) (when (and (buffers:live? b) (null? (%conns-of b))) (%tear-down-buffer! b) (buffers:with-buffer b (managed b))))) docs)
        (ask:message (%fmt "~a exited with status ~a" (%conn-title conn) status))
        (unless asked?
          (let ([again (autoreconnect)])
            (cond
              [(or (eq? again #t) (and (real? again) (>= ran again)))
               (ask:message "Reconnecting after unexpected server exit.")
               (let ([new (%start! (%conn-name conn) (tables:ref servers (%conn-name conn) (%conn-description conn)) (%conn-root conn) (%conn-folder conn))])
                 (for-each (lambda (d) (let ([b (%doc-buffer d)]) (when (buffers:live? b) (%manage! new b (%doc-path d))))) docs))
               (ask:message "Reconnected!")]
              [again (ask:message "Not auto-reconnecting, last one didn't last long.")])))))))


(define (%shutdown! conn)
  (%conn-shutting-down?-set! conn #t)
  (let ([rpc (%conn-rpc conn)])
    (when (jsonrpc:running? rpc)
      (ask:message (%fmt "Asking ~a politely to terminate" (%conn-title conn)))
      (for-each (lambda (d) (%close! conn d)) (%conn-docs conn))
      (guard (c [(not (cancelled? c)) (void)])
        (when (%conn-ready? conn)
          (jsonrpc:request rpc "shutdown" 'null 1.5)
          (jsonrpc:notify rpc "exit" 'null)))
      (let wait ([n 0])
        (when (and (jsonrpc:running? rpc) (< n 15))
          (timers:sleep 0.1)
          (wait (+ n 1))))
      (when (jsonrpc:running? rpc) (jsonrpc:stop! rpc)))))

(define (%current-conn who)
  (let* ([b (buffers:current)] [conns (if b (%ordered-conns b) '())])
    (cond
      [(null? conns) (error who "The buffer is managed by no server")]
      [(null? (cdr conns)) (%conn-rpc (car conns))]
      [else (ask:choice "Connection: " (map (lambda (c) (cons (%conn-title c) (%conn-rpc c))) conns))])))

(commands:define-command (shutdown [c (%current-conn 'lsp:shutdown)])
  "Asks connection C's server to shut down and exit, stopping it when it has not exited after 1.5 seconds."
  (%shutdown! (%conn-of 'lsp:shutdown c)))

(commands:define-command (shutdown-all)
  "Shuts down every connection."
  (for-each %shutdown! %connections))

(commands:define-command (reconnect [c (%current-conn 'lsp:reconnect)])
  "Shuts down connection C and starts its server again for the same root and buffers, with its description now."
  (let* ([conn (%conn-of 'lsp:reconnect c)] [docs (%conn-docs conn)])
    (%shutdown! conn)
    (let ([new (%start! (%conn-name conn) (tables:ref servers (%conn-name conn) (%conn-description conn)) (%conn-root conn) (%conn-folder conn))])
      (for-each (lambda (d) (let ([b (%doc-buffer d)]) (when (buffers:live? b) (%manage! new b (%doc-path d))))) docs)
      (ask:message "Reconnected!"))))

(commands:define-command (send-configuration [c (%current-conn 'lsp:send-configuration)])
  "Sends connection C its server's configuration as lsp:servers describes it now."
  (%send-configuration! (%conn-of 'lsp:send-configuration c)))

(commands:define-command (show-events [c (%current-conn 'lsp:show-events)])
  "Shows the events log of connection C."
  (layout:display-buffer (jsonrpc:events-buffer c)))

(commands:define-command (start)
  "Starts the current buffer's connections, after asking whether to shut down those running, and makes it managed; with C-u, asks for each server's command line."
  (let ([b (buffers:current)])
    (unless (and b (files:path b))
      (error 'lsp:start "The buffer visits no file"))
    (let ([running (%conns-of b)])
      (when (and (pair? running) (ask:yes-or-no? "Shut down the buffer's servers first? "))
        (for-each %shutdown! running)))
    (when (commands:prefix-argument)
      (let* ([language (%language-id b)] [spec (or (and language (tables:ref language-servers language #f)) '())])
        (for-each
          (lambda (element)
            (let* ([name (%resolve b element)] [description (and name (tables:ref servers name #f))])
              (when description
                (let ([line (ask:line (%fmt "Command for ~a: " name)
                              (let ([c (%server-command description)]) (if (procedure? c) "" (%join c))))])
                  (tables:set! servers name
                    (%make-server (%split-on line #\space) (%server-initialization-options description)
                                  (%server-configuration description) (%server-root description)
                                  (%server-ignored description) (%server-capabilities description)))))))
          spec)))
    (%ensure! b)))

(define (%join words) (fold-left (lambda (acc w) (if (string=? acc "") w (string-append acc " " w))) "" words))

(define (%killed b)
  (for-each
    (lambda (conn)
      (%release! conn b)
      (when (and (autoshutdown?) (null? (%conn-docs conn)))
        (spawn-task (lambda (restore) (%shutdown! conn)))))
    (%conns-of b)))

;; A mode change drops the buffer's scope with the local entries; the
;; connections that served the old mode let it go unless a mode hook's
;; lsp:ensure kept it.
(define (%mode-changed b)
  (for-each
    (lambda (conn)
      (let ([d (%doc-of conn b)])
        (when (and d (not (eq? (%doc-mode d) (modes:major-mode b))))
          (%release! conn b))))
    (%conns-of b))
  (when (pair? (%conns-of b))
    (%set-up-buffer! b #t)
    (for-each (lambda (conn) (%add-doc-entries! conn b)) (%conns-of b))))

(define (%renamed from to)
  (for-each
    (lambda (conn)
      (for-each
        (lambda (d)
          (let ([new (files:renamed-path (%doc-path d) from to)])
            (when new
              (%close! conn d)
              (%doc-path-set! d new)
              (when (%conn-ready? conn) (%open! conn d)))))
        (%conn-docs conn)))
    %connections))

(define (%will-save b)
  (for-each
    (lambda (conn)
      (let ([d (%doc-of conn b)])
        (when (and d (%doc-opened? d))
          (%flush! conn)
          (let ([sync (%ref (%conn-caps conn) "textDocumentSync")])
            (when (and (pair? sync) (eq? (%ref sync "willSave") #t))
              (jsonrpc:notify (%conn-rpc conn) "textDocument/willSave" `(("textDocument" . ,(%doc-identifier conn b)) ("reason" . 1))))
            (when (and (pair? sync) (eq? (%ref sync "willSaveWaitUntil") #t))
              (let ([version (buffers:version b)])
                (guard (c [(not (cancelled? c)) (void)])
                  (let ([edits (jsonrpc:request (%conn-rpc conn) "textDocument/willSaveWaitUntil"
                                 `(("textDocument" . ,(%doc-identifier conn b)) ("reason" . 1)) 0.5)])
                    (%apply-text-edits! conn b (%list edits) version)))))))))
    (%ordered-conns b)))

(define (%did-save b)
  (for-each
    (lambda (conn)
      (let ([d (%doc-of conn b)])
        (when (and d (%doc-opened? d))
          (let* ([sync (%ref (%conn-caps conn) "textDocumentSync")] [save (and (pair? sync) (%ref sync "save"))])
            (when save
              (%flush! conn)
              (jsonrpc:notify (%conn-rpc conn) "textDocument/didSave"
                `(("textDocument" . ,(%doc-identifier conn b))
                  ,@(if (and (pair? save) (eq? (%ref save "includeText") #t)) `(("text" . ,(%text b))) '()))))))))
    (%conns-of b)))


(define (%check-version! conn b version)
  (unless (eqv? (buffers:version b) version)
    (error 'lsp (%fmt "~a changed while ~a answered" (buffers:name b) (%conn-title conn)))))

(define-record-type (%text-edit %make-text-edit %text-edit?)
  (sealed #t)
  (fields start end text index))

(define-record-type (%hunk %make-hunk %hunk?)
  (sealed #t)
  (fields old-start old-end new-start new-end))

(define-record-type (%place %make-place %place?)
  (sealed #t)
  (fields (mutable position) indentation point?))

(define-record-type (%cursor-places %make-cursor-places %cursor-places?)
  (sealed #t)
  (fields view cursor point mark))

;; Last first, so each edit's positions hold when it is applied. At one
;; start a replacement goes first and the inserts after it, the later in
;; the list first, so the inserts appear in the list's order before the
;; replacement's text, and an insert listed after a replacement, which
;; the protocol does not allow, is still kept.
(define (%apply-text-edits! conn b edits version)
  (unless (null? edits)
    (%check-version! conn b version)
    (let* ([doc (buffers:document b)]
           [placed (map (lambda (e i)
                          (let-values ([(s en) (%bounds-at doc (%ref e "range") (%conn-encoding conn))])
                            (%make-text-edit s en (or (%ref e "newText") "") i)))
                        edits (iota (length edits)))]
           [cursors (%cursors-showing b)]
           [places (fold-right (lambda (c acc) (append (filter values (list (%cursor-places-point c) (%cursor-places-mark c))) acc))
                               '() cursors)]
           [budget (box %difference-budget)])
      (parameterize ([%server-edits? #t])
        (for-each (lambda (e) (%apply-text-edit! b e budget places))
                  (list-sort %applied-before? placed)))
      (%place-cursors! b cursors)))
  (void))

(define (%applied-before? x y)
  (let ([xs (%text-edit-start x)] [ys (%text-edit-start y)])
    (or (fx> xs ys)
        (and (fx= xs ys)
             (let ([x-replaces? (fx< xs (%text-edit-end x))] [y-replaces? (fx< ys (%text-edit-end y))])
               (or (and x-replaces? (not y-replaces?))
                   (and (eq? x-replaces? y-replaces?) (fx> (%text-edit-index x) (%text-edit-index y)))))))))

;; A server's edits are not typing, and an on-type request made from one
;; of them would name a position the edits after it move.
(define %server-edits? (make-thread-parameter #f))

;; One replacement for the span the differences cover, not one for each
;; difference, so after-edit hooks, undo and every server see one change
;; for each change the server sent, as Emacs announces one modification
;; for replace-region-contents. Past the budget, as Emacs's
;; replace-region-contents falls back past its MAX-SECS, a cursor inside
;; the range has no difference to follow.
(define (%apply-text-edit! b edit budget places)
  (let* ([doc (buffers:document b)] [start (%text-edit-start edit)] [end (%text-edit-end edit)] [text (%text-edit-text edit)]
         [old (let ([v (make-vector (fx- end start))])
                (do ([q start (fx+ q 1)]) ((fx= q end) v) (vector-set! v (fx- q start) (document:token doc q))))]
         [hunks (%differences old text budget)])
    (cond
      [(not hunks)
       (let ([whole (list (%make-hunk 0 (fx- end start) 0 (string-length text)))])
         (for-each
           (lambda (place)
             (let ([p (%place-position place)])
               (%place-position-set! place
                 (if (fx< start p end) (%same-line-and-column doc start text p) (%carried place start whole)))))
           places)
         (buffers:replace! b start end text))]
      [(pair? hunks)
       (let ([first (car hunks)] [last (car (last-pair hunks))])
         (for-each (lambda (place) (%place-position-set! place (%carried place start hunks))) places)
         (buffers:replace! b (fx+ start (%hunk-old-start first)) (fx+ start (%hunk-old-end last))
           (substring text (%hunk-new-start first) (%hunk-new-end last))))])))

;; Text inserted at a point goes before it, so the cursor stays before
;; the text that followed it, as Emacs keeps point through
;; replace-region-contents and VS Code moves cursors through formatting
;; edits; a mark stays before text inserted at it, as Emacs's mark, a
;; marker, does.
(define (%carried place start hunks)
  (let ([q (fx- (%place-position place) start)])
    (let loop ([hs hunks] [delta 0])
      (if (null? hs)
          (fx+ start q delta)
          (let* ([h (car hs)] [s (%hunk-old-start h)] [e (%hunk-old-end h)] [inserted (fx- (%hunk-new-end h) (%hunk-new-start h))])
            (cond
              [(fx< q s) (fx+ start q delta)]
              [(fx= q s) (fx+ start q delta (if (and (fx= s e) (%place-point? place)) inserted 0))]
              [(fx< q e) (fx+ start s delta)]
              [else (loop (cdr hs) (fx+ delta (fx- inserted (fx- e s))))]))))))

(define (%same-line-and-column doc start text p)
  (let* ([line (document:line doc p)] [lines (fx- line (document:line doc start))]
         [column (fx- p (if (fx= lines 0) start (document:line-start doc line)))]
         [n (string-length text)])
    (let find ([i 0] [left lines])
      (cond
        [(fx= left 0)
         (let run ([j i])
           (if (or (fx= j n) (fx= (fx- j i) column) (char=? (string-ref text j) #\newline)) (fx+ start j) (run (fx+ j 1))))]
        [(fx= i n) (fx+ start n)]
        [else (find (fx+ i 1) (if (char=? (string-ref text i) #\newline) (fx- left 1) left))]))))

;; Measured, formatting every line of a 390,000-character document as
;; one edit spends 16,000,000, a quarter of a second.
(define %difference-budget 20000000)

;; With the search capped at this many differences, as Emacs's MAX-COSTS
;; caps it, a split is taken from the furthest point reached; measured,
;; whole-document formatting stays minimal or within a few characters of
;; it, and the time grows with the length rather than its square.
(define %difference-search-limit 64)

;; Split at the middle snake, so that it takes space linear in the
;; lengths.
(define (%differences old new budget)
  (define give-up #f)
  (define (same? i j) (eqv? (vector-ref old i) (string-ref new j)))
  (define (spend! n)
    (let ([left (fx- (unbox budget) n)])
      (set-box! budget left)
      (when (fx< left 0) (give-up #f))))
  (define (add hunk tail)
    (if (and (pair? tail) (fx= (%hunk-old-end hunk) (%hunk-old-start (car tail))) (fx= (%hunk-new-end hunk) (%hunk-new-start (car tail))))
        (cons (%make-hunk (%hunk-old-start hunk) (%hunk-old-end (car tail)) (%hunk-new-start hunk) (%hunk-new-end (car tail))) (cdr tail))
        (cons hunk tail)))
  (define (furthest a0 b0 n m limit size forward backward)
    (let loop ([o 0] [fx -1] [fy -1] [bx -1] [by -1])
      (if (fx= o size)
          (if (fx>= (fx+ fx fy) (fx+ bx by))
              (values (fx+ a0 fx) (fx+ b0 fy))
              (values (fx+ a0 (fx- n bx)) (fx+ b0 (fx- m by))))
          (let ([k (fx- o limit)])
            (define (clamped x)
              (let* ([x (fxmin x n)] [y (fx- x k)])
                (if (fx> y m) (values (fx+ m k) m) (values x y))))
            (let-values ([(x y) (if (fx= (vector-ref forward o) -1) (values -1 -1) (clamped (vector-ref forward o)))]
                         [(x2 y2) (if (fx= (vector-ref backward o) -1) (values -1 -1) (clamped (vector-ref backward o)))])
              (let-values ([(fx fy) (if (and (fx>= y 0) (fx>= x 0) (fx> (fx+ x y) (fx+ fx fy))) (values x y) (values fx fy))]
                           [(bx by) (if (and (fx>= y2 0) (fx>= x2 0) (fx> (fx+ x2 y2) (fx+ bx by))) (values x2 y2) (values bx by))])
                (loop (fx+ o 1) fx fy bx by)))))))
  (define (middle a0 a1 b0 b1)
    (let* ([n (fx- a1 a0)] [m (fx- b1 b0)] [limit (fxmin (fxquotient (fx+ n m 1) 2) (fx+ %difference-search-limit 1))] [size (fx+ (fx* 2 limit) 2)]
           [forward (make-vector size -1)] [backward (make-vector size -1)]
           [delta (fx- n m)] [front? (fxodd? delta)])
      (spend! size)
      (vector-set! forward (fx+ limit 1) 0)
      (vector-set! backward (fx+ limit 1) 0)
      (call/1cc
        (lambda (return)
          (let ([k1start 0] [k1end 0] [k2start 0] [k2end 0])
            (do ([d 0 (fx+ d 1)]) ((fx= d limit) (values #f #f))
              (when (fx= d %difference-search-limit)
                (call-with-values (lambda () (furthest a0 b0 n m limit size forward backward)) return))
              (do ([k (fx+ (fx- d) k1start) (fx+ k 2)]) ((fx> k (fx- d k1end)))
                (let* ([o (fx+ limit k)]
                       [x0 (if (or (fx= k (fx- d)) (and (not (fx= k d)) (fx< (vector-ref forward (fx- o 1)) (vector-ref forward (fx+ o 1)))))
                               (vector-ref forward (fx+ o 1))
                               (fx+ (vector-ref forward (fx- o 1)) 1))]
                       [x (let loop ([x x0])
                            (if (and (fx< x n) (fx< (fx- x k) m) (same? (fx+ a0 x) (fx+ b0 (fx- x k)))) (loop (fx+ x 1)) x))]
                       [y (fx- x k)])
                  (spend! (fx+ 1 (fx- x x0)))
                  (vector-set! forward o x)
                  (cond
                    [(fx> x n) (set! k1end (fx+ k1end 2))]
                    [(fx> y m) (set! k1start (fx+ k1start 2))]
                    [front?
                     (let ([o2 (fx+ limit (fx- delta k))])
                       (when (and (fx< -1 o2 size) (not (fx= (vector-ref backward o2) -1))
                                  (fx>= x (fx- n (vector-ref backward o2))))
                         (return (fx+ a0 x) (fx+ b0 y))))])))
              (do ([k (fx+ (fx- d) k2start) (fx+ k 2)]) ((fx> k (fx- d k2end)))
                (let* ([o (fx+ limit k)]
                       [x0 (if (or (fx= k (fx- d)) (and (not (fx= k d)) (fx< (vector-ref backward (fx- o 1)) (vector-ref backward (fx+ o 1)))))
                               (vector-ref backward (fx+ o 1))
                               (fx+ (vector-ref backward (fx- o 1)) 1))]
                       [x (let loop ([x x0])
                            (if (and (fx< x n) (fx< (fx- x k) m) (same? (fx- a1 x 1) (fx- b1 (fx- x k) 1))) (loop (fx+ x 1)) x))]
                       [y (fx- x k)])
                  (spend! (fx+ 1 (fx- x x0)))
                  (vector-set! backward o x)
                  (cond
                    [(fx> x n) (set! k2end (fx+ k2end 2))]
                    [(fx> y m) (set! k2start (fx+ k2start 2))]
                    [(not front?)
                     (let ([o1 (fx+ limit (fx- delta k))])
                       (when (and (fx< -1 o1 size) (not (fx= (vector-ref forward o1) -1)))
                         (let ([x1 (vector-ref forward o1)])
                           (when (fx>= x1 (fx- n x))
                             (return (fx+ a0 x1) (fx+ b0 (fx- (fx+ limit x1) o1)))))))])))))))))
  (call/1cc
    (lambda (k)
      (set! give-up k)
      (let walk ([a0 0] [a1 (vector-length old)] [b0 0] [b1 (string-length new)] [tail '()])
        (let prefix ([a0 a0] [b0 b0])
          (if (and (fx< a0 a1) (fx< b0 b1) (same? a0 b0))
              (prefix (fx+ a0 1) (fx+ b0 1))
              (let suffix ([a1 a1] [b1 b1])
                (cond
                  [(and (fx< a0 a1) (fx< b0 b1) (same? (fx- a1 1) (fx- b1 1))) (suffix (fx- a1 1) (fx- b1 1))]
                  [(and (fx= a0 a1) (fx= b0 b1)) tail]
                  [(or (fx= a0 a1) (fx= b0 b1)) (add (%make-hunk a0 a1 b0 b1) tail)]
                  [else
                   (let-values ([(x y) (middle a0 a1 b0 b1)])
                     (if (and x (not (and (fx= x a0) (fx= y b0))) (not (and (fx= x a1) (fx= y b1))))
                         (walk a0 x b0 y (walk x a1 y b1 tail))
                         (add (%make-hunk a0 a1 b0 b1) tail)))]))))))))

(define (%indentation-bounds doc p)
  (let ([start (fxmax (%content-start doc) (document:line-start doc (document:line doc p)))] [end (%content-end doc)])
    (values start (let loop ([q start]) (if (and (fx< q end) (memv (document:token doc q) '(#\space #\tab))) (loop (fx+ q 1)) q)))))

(define (%point-place doc p)
  (let-values ([(start end) (%indentation-bounds doc p)])
    (%make-place p (and (fx<= start p end) (buffers:text-between doc start end)) #t)))

(define (%cursors-showing b)
  (let ([doc (buffers:document b)])
    (apply append
      (map (lambda (v)
             (map (lambda (c)
                    (let ([m (views:cursor-mark c)])
                      (%make-cursor-places v c (%point-place doc (views:cursor-point c)) (and m (%make-place m #f #f)))))
                  (views:cursors v)))
           (views:showing b)))))

;; A point in leading whitespace the edits change goes to the end of the
;; line's new indentation, as Emacs's indent-line-to leaves point, since
;; the difference of two runs of spaces could put the added ones on
;; either side of it.
(define (%place-cursors! b cursors)
  (let ([doc (buffers:document b)])
    (define (final place)
      (and place
           (let ([p (fxmin (%place-position place) (%content-end doc))] [indentation (%place-indentation place)])
             (if indentation
                 (let-values ([(start end) (%indentation-bounds doc p)])
                   (if (or (fx> p end) (string=? indentation (buffers:text-between doc start end))) p end))
                 p))))
    (for-each
      (lambda (places)
        (let ([v (%cursor-places-view places)] [c (%cursor-places-cursor places)])
          (when (and (eq? (views:buffer v) b) (memq c (views:cursors v)))
            (let ([p (final (%cursor-places-point places))] [m (final (%cursor-places-mark places))])
              (unless (and (eqv? p (views:cursor-point c)) (eqv? m (views:cursor-mark c)))
                (views:set-cursor! c p m))))))
      cursors)))

(define (%edit-paths edit)
  (let ([changes (%ref edit "changes")] [document-changes (%list (%ref edit "documentChanges"))])
    (append (if (list? changes) (map (lambda (p) (uri->path (car p))) changes) '())
            (fold-right (lambda (dc acc)
                          (let ([uri (or (%ref dc "textDocument" "uri") (%ref dc "uri") (%ref dc "oldUri"))])
                            (if (string? uri) (cons (uri->path uri) acc) acc)))
                        '() document-changes))))

(define (%resource-operations? edit)
  (exists (lambda (dc) (string? (%ref dc "kind"))) (%list (%ref edit "documentChanges"))))

(define (%confirm! edit)
  (let* ([paths (%edit-paths edit)]
         [unvisited (filter (lambda (p) (not (files:buffer-visiting p))) paths)]
         [ask? (case (confirm-edits)
                 [(always) #t]
                 [(unvisited) (or (pair? unvisited) (%resource-operations? edit))]
                 [else #f])])
    (when (and ask? (pair? paths))
      (unless (ask:yes-or-no? (%fmt "Apply changes to ~a? "
                                (fold-left (lambda (acc p) (string-append acc ", " p)) (files:abbreviated-path (car paths))
                                           (map files:abbreviated-path (cdr paths)))))
        (error 'lsp "Changes not applied")))))

(define (%apply-workspace-edit! conn edit versions)
  (when (pair? edit)
    (%confirm! edit)
    (let* ([changes (%ref edit "changes")]
           [steps (append
                    (if (list? changes) (map (lambda (p) (list 'edit (uri->path (car p)) #f (%list (cdr p)))) changes) '())
                    (map (lambda (dc)
                           (let ([kind (%ref dc "kind")])
                             (cond
                               [(equal? kind "create") (list 'create (uri->path (%ref dc "uri")))]
                               [(equal? kind "rename") (list 'rename (uri->path (%ref dc "oldUri")) (uri->path (%ref dc "newUri")))]
                               [(equal? kind "delete") (list 'delete (uri->path (%ref dc "uri")))]
                               [else (list 'edit (uri->path (%ref dc "textDocument" "uri")) (%ref dc "textDocument" "version")
                                           (%list (%ref dc "edits")))])))
                         (%list (%ref edit "documentChanges"))))]
           [version-of (lambda (b given)
                         (or given (let ([v (and versions (assq b versions))]) (and v (cdr v))) (buffers:version b)))])
      (for-each
        (lambda (step)
          (when (eq? (car step) 'edit)
            (let ([b (files:buffer-visiting (cadr step))])
              (when b (%check-version! conn b (version-of b (caddr step)))))))
        steps)
      (for-each
        (lambda (step)
          (case (car step)
            [(edit)
             (let* ([existing (files:buffer-visiting (cadr step))] [b (or existing (files:visit (cadr step)))])
               (%apply-text-edits! conn b (cadddr step) (if existing (version-of b (caddr step)) (buffers:version b))))]
            [(create) (unless (file-exists? (cadr step)) (call-with-output-file (cadr step) (lambda (p) (void))))]
            [(rename) (files:rename-file (cadr step) (caddr step))]
            [(delete) (files:delete-file (cadr step))]))
        steps))))

(define (execute-command c command)
  (let* ([conn (%conn-of 'lsp:execute-command c)] [name (%ref command "command")]
         [arguments (or (%ref command "arguments") (vector))] [local (and (string? name) (tables:ref commands name #f))])
    (if local
        (local c (if (vector? arguments) arguments (list->vector (%list arguments))))
        (request c "workspace/executeCommand" `(("command" . ,name) ("arguments" . ,arguments))))
    (void)))


(define (%trigger-characters conns)
  (fold-left
    (lambda (acc conn)
      (fold-left (lambda (acc s) (if (and (string? s) (fx= (string-length s) 1) (not (memv (string-ref s 0) acc)))
                                     (cons (string-ref s 0) acc) acc))
                 acc (%list (%ref (%conn-caps conn) "completionProvider" "triggerCharacters"))))
    '() conns))

(define (completion-region)
  (let* ([view (views:current)] [b (and view (views:buffer view))]
         [conns (if b (%give (%ordered-conns b) 'completion b) '())])
    (and (pair? conns)
         (let ([p (views:point view)])
           (let-values ([(s e) (guard (c [(not (cancelled? c)) (values #f #f)]) (syntax:symbol-bounds b p))])
             (let ([s (or s p)] [e (if e (fxmax e p) p)])
               (completion:region s e (map (lambda (conn) (%completion-source conn b view s)) conns)
                                  (%trigger-characters conns))))))))

(define-record-type %asked
  (sealed #t)
  (fields conn buffer start text version item))

(define (%completion-items result)
  (cond
    [(vector? result) (values (vector->list result) #f)]
    [(pair? result) (values (%list (%ref result "items")) (eq? (%ref result "isIncomplete") #t))]
    [else (values '() #f)]))

(define (%completion-source conn b view start)
  (completion:source
    (stream (%completion-stream conn b view start))
    (split string-length)
    (title (%conn-title conn))
    (exit (lambda (asked status) (%completion-exit asked)))))

(define (%completion-stream conn b view start)
  (lambda (emit)
    (let ([pending #f] [incomplete? #t] [asked? #f])
      (define (cancel!) (when pending (jsonrpc:cancel! pending) (set! pending #f)))
      (define (ask!)
        (cancel!)
        (%flush! conn)
        (let* ([p (views:point view)] [version (buffers:version b)] [doc (buffers:document b)]
               [text (buffers:text-between doc start p)])
          (set! pending
            (jsonrpc:request-async (%conn-rpc conn) "textDocument/completion" (%point-params conn b p)
              (lambda (result)
                (set! pending #f)
                (let-values ([(items incomplete) (%completion-items result)])
                  (set! incomplete? incomplete)
                  (let* ([sorted (list-sort (lambda (x y) (string<? (or (%ref x "sortText") (%ref x "label") "")
                                                                    (or (%ref y "sortText") (%ref y "label") "")))
                                            items)]
                         [ranks (map (lambda (item) (let loop ([i 0] [l sorted]) (if (eq? (car l) item) i (loop (fx+ i 1) (cdr l))))) items)])
                    (emit 'clear)
                    (emit (list 'base 0))
                    (emit (cons (list->vector (map (lambda (item) (cons (or (%ref item "label") "") (make-%asked conn b start text version item))) items))
                                (list->vector ranks)))
                    (emit 'done))))
              (lambda (c) (set! pending #f) (emit 'done))))))
      (lambda (prefix)
        (cond
          [(eof-object? prefix) (cancel!)]
          [(or (not asked?) incomplete?) (set! asked? #t) (ask!)]
          [else (emit 'done)])))))

;; The item's edit is counted on the text the request saw, so the
;; region's text is put back as it was before the edit applies.
(define (%completion-exit asked)
  (let* ([conn (%asked-conn asked)] [b (%asked-buffer asked)] [item (%asked-item asked)]
         [view (views:current)] [start (%asked-start asked)]
         [label (or (%ref item "label") "")])
    (when (and view (buffers:live? b))
      (let ([end (fxmin (fx+ start (string-length label)) (%content-end (buffers:document b)))])
        (buffers:replace! b start end (%asked-text asked)))
      (let* ([doc (buffers:document b)] [edit (%ref item "textEdit")] [request-end (fx+ start (string-length (%asked-text asked)))])
        (let-values ([(s e text)
                      (if (pair? edit)
                          (let-values ([(s e) (%bounds-at doc (or (%ref edit "range") (%ref edit "replace")) (%conn-encoding conn))])
                            (values s e (or (%ref edit "newText") "")))
                          (values start request-end (or (%ref item "insertText") label)))])
          (buffers:replace! b s e text)
          (views:set-point! view (fx+ s (string-length text)))
          (let ([extra (%list (%ref item "additionalTextEdits"))])
            (unless (null? extra)
              (%apply-text-edits! conn b extra (buffers:version b))))
          (let ([command (%ref item "command")])
            (when (pair? command)
              (call-as-owner %self (lambda () (spawn-task (lambda (restore) (execute-command (%conn-rpc conn) command))))))))))))


(define (%location-parts location)
  (if (%ref location "targetUri")
      (values (%ref location "targetUri") (or (%ref location "targetSelectionRange") (%ref location "targetRange")))
      (values (%ref location "uri") (%ref location "range"))))

(define (%items conn locations versions)
  (let* ([parts (map (lambda (l) (let-values ([(uri r) (%location-parts l)]) (cons (uri->path uri) r))) locations)]
         [unvisited (filter (lambda (p) (not (files:buffer-visiting (car p)))) parts)]
         [wanted (fold-left (lambda (acc p)
                              (let ([old (assoc (car p) acc)] [line (or (%ref (cdr p) "start" "line") 0)])
                                (if old
                                    (map (lambda (e) (if (eq? e old) (cons (car e) (cons line (cdr e))) e)) acc)
                                    (append acc (list (list (car p) line))))))
                            '() unvisited)]
         [lines (%file-lines wanted)])
    (when (extend-to-xref?)
      (for-each (lambda (p) (unless (hashtable-ref %xref-reached (car p) #f) (hashtable-set! %xref-reached (car p) conn))) parts))
    (filter values
      (map (lambda (p)
             (let* ([path (car p)] [r (cdr p)] [b (files:buffer-visiting path)])
               (if b
                   (let* ([v (or (let ([e (assq b versions)]) (and e (cdr e))) (buffers:version b))]
                          [doc (or (buffers:document-at b v) (buffers:document b))])
                     (let-values ([(s e) (%bounds-at doc r (%conn-encoding conn))])
                       (let* ([line (document:line doc s)] [ls (%clamp doc (document:line-start doc line))]
                              [le (%line-end doc line)])
                         (xref:make-item (buffers:text-between doc ls le) path line
                           (fx- (document:offset doc s (document:unit characters)) (document:offset doc ls (document:unit characters)))))))
                   (let* ([line (or (%ref r "start" "line") 0)]
                          [text (let ([f (assoc path lines)]) (or (and f (let ([l (assv line (cdr f))]) (and l (cdr l)))) ""))])
                     (xref:make-item text path (fx+ line 1)
                       (%character-column text (or (%ref r "start" "character") 0) (%conn-encoding conn)))))))
           parts))))

(define (location->item c location)
  (let ([conn (%conn-of 'lsp:location->item c)])
    (car (%items conn (list location) '()))))

(define (%versions conns)
  (apply append (map (lambda (conn) (map (lambda (d) (cons (%doc-buffer d) (buffers:version (%doc-buffer d)))) (%conn-docs conn))) conns)))

(define (%locations result) (if (vector? result) (vector->list result) (if (pair? result) (list result) '())))

;; An identifier from point carries its place, so its definitions are asked
;; there; a typed one is looked up by name.
(define %identifier-places (make-weak-eq-hashtable))

(define (%identifier-at view)
  (let* ([b (views:buffer view)] [p (views:point view)])
    (let-values ([(s e) (guard (c [(not (cancelled? c)) (values #f #f)]) (syntax:symbol-bounds b p))])
      (and s (fx< s e)
           (let ([name (buffers:text-between (buffers:document b) s e)])
             (eq-hashtable-set! %identifier-places name (cons b p))
             name)))))

(define (%place-requests b feature method extra)
  (lambda (name)
    (let ([place (eq-hashtable-ref %identifier-places name #f)])
      (if (and place (eq? (car place) b))
          (apply append
            (map (lambda (conn)
                   (%flush! conn)
                   (let* ([versions (%versions (list conn))]
                          [result (jsonrpc:request (%conn-rpc conn) method (append (%point-params conn b (cdr place)) extra))])
                     (%items conn (%locations result) versions)))
                 (%give (%ordered-conns b) feature b)))
          (filter (lambda (item) (string=? (xref:item-summary item) name)) ((%apropos b) name))))))

(define (%symbols conn b query)
  (%flush! conn)
  (let ([result (jsonrpc:request (%conn-rpc conn) "workspace/symbol" `(("query" . ,query)))])
    (map (lambda (s) (cons (or (%ref s "name") "") (%ref s "location"))) (%list result))))

(define (%apropos b)
  (lambda (pattern)
    (apply append
      (map (lambda (conn)
             (let ([symbols (%symbols conn b pattern)] [versions (%versions (list conn))])
               (map (lambda (item symbol) (xref:make-item (car symbol) (xref:item-path item) (xref:item-line item) (xref:item-column item)))
                    (%items conn (filter values (map cdr symbols)) versions)
                    (filter cdr symbols))))
           (%give (%ordered-conns b) 'workspace-symbol b)))))

(define (xref-backend view)
  (let ([b (views:buffer view)])
    (and b (pair? (%conns-of b))
         (xref:backend "lsp"
           [identifier-at-point %identifier-at]
           [identifiers (lambda (input)
                          (apply append (map (lambda (conn) (map car (%symbols conn b input)))
                                             (%give (%ordered-conns b) 'workspace-symbol b))))]
           [definitions (%place-requests b 'definition "textDocument/definition" '())]
           [references (%place-requests b 'references "textDocument/references" '(("context" ("includeDeclaration" . #t))))]
           [apropos (%apropos b)]))))

(define (%find-at who feature method title)
  (let* ([view (views:current)] [b (views:buffer view)] [name (%identifier-at view)])
    (unless name (error who "No identifier here"))
    (let ([items ((%place-requests b feature method '()) name)])
      (when (null? items) (error who (%fmt "No ~a found for: ~a" title name)))
      (xref:show-items items (%fmt "~a of ~a" (string-titlecase title) name)))))

(commands:define-command (find-declaration)
  "Shows the declarations of the identifier at point."
  (%find-at 'lsp:find-declaration 'declaration "textDocument/declaration" "declarations"))

(commands:define-command (find-implementation)
  "Shows the implementations of the identifier at point."
  (%find-at 'lsp:find-implementation 'implementation "textDocument/implementation" "implementations"))

(commands:define-command (find-type-definition)
  "Shows the definitions of the type of the identifier at point."
  (%find-at 'lsp:find-type-definition 'type-definition "textDocument/typeDefinition" "type definitions"))


(define (%markup contents)
  (cond
    [(string? contents) contents]
    [(vector? contents) (%join-blocks (map %markup (vector->list contents)))]
    [(pair? contents)
     (let ([value (%ref contents "value")] [language (%ref contents "language")])
       (cond
         [(string? language) (string-append "```" language "\n" (or value "") "\n```")]
         [(string? value) value]
         [else ""]))]
    [else ""]))

(define (%join-blocks parts)
  (fold-left (lambda (acc s) (cond [(string=? s "") acc] [(string=? acc "") s] [else (string-append acc "\n\n" s)])) "" parts))

(define (hover c view)
  (let* ([conn (%conn-of 'lsp:hover c)] [b (views:buffer view)]
         [result (request c "textDocument/hover" (%point-params conn b (views:point view)))]
         [text (and (pair? result) (%markup (%ref result "contents")))])
    (and text (not (string=? text ""))
         (docs-at-point:make-doc text (docs-at-point:doc-options [markdown] [echo (%echo-text text)])))))

;; A hover's docstring would fill the echo area, and a fence's marks would
;; take its first line.
(define (%echo-text markdown)
  (let ([lines (filter (lambda (l) (not (or (%starts-with? l "```") (string=? l "---") (string=? l ""))))
                       (%split-on markdown #\newline))])
    (if (pair? lines) (car lines) "")))

(define (%starts-with? s prefix)
  (and (fx>= (string-length s) (string-length prefix)) (string=? (substring s 0 (string-length prefix)) prefix)))


(define (%parameter-span label parameter)
  (let ([l (%ref parameter "label")])
    (cond
      [(string? l)
       (let loop ([i 0])
         (cond
           [(> (+ i (string-length l)) (string-length label)) #f]
           [(string=? (substring label i (+ i (string-length l))) l) (list i (+ i (string-length l)))]
           [else (loop (+ i 1))]))]
      [(and (vector? l) (fx= (vector-length l) 2))
       (list (%character-column label (vector-ref l 0) "utf-16") (%character-column label (vector-ref l 1) "utf-16"))]
      [else #f])))

(define (signature c view)
  (let* ([conn (%conn-of 'lsp:signature c)] [b (views:buffer view)]
         [result (request c "textDocument/signatureHelp" (%point-params conn b (views:point view)))]
         [signatures (%list (and (pair? result) (%ref result "signatures")))])
    (and (pair? signatures)
         (let* ([active (or (%ref result "activeSignature") 0)]
                [sig (if (and (fixnum? active) (fx< active (length signatures))) (list-ref signatures active) (car signatures))]
                [label (or (%ref sig "label") "")]
                [parameters (%list (%ref sig "parameters"))]
                [n (or (%ref sig "activeParameter") (%ref result "activeParameter") 0)]
                [span (and (fixnum? n) (fx< n (length parameters)) (%parameter-span label (list-ref parameters n)))])
           (docs-at-point:make-doc label
             (docs-at-point:doc-options [spans (if span (list (append span (list faces:highlight))) '())]))))))

;; Each connection's hover and signature are entries of their own, so a
;; slow server holds back no other's docs.
(define (%add-doc-entries! conn b)
  (call-as-owner %self
    (lambda ()
      (buffers:with-buffer b
        (let ([d (%doc-of conn b)])
          (when d
            (hooks:add-local! docs-at-point:sources (%entry-for conn 'signature-help signature) -20)
            (hooks:add-local! docs-at-point:sources (%entry-for conn 'hover hover) -10)))))))

(define %entries (make-weak-eq-hashtable))

(define (%entry-for conn feature ask)
  (let ([key (cons conn feature)])
    (or (let ([e (find (lambda (e) (and (eq? (caar e) conn) (eq? (cdar e) feature))) (eq-hashtable-ref %entries conn '()))]) (and e (cdr e)))
        (let ([entry (lambda (view)
                       (let ([b (views:buffer view)])
                         (and (%offers? conn feature b)
                              (guard (c [(not (cancelled? c)) #f]) (ask (%conn-rpc conn) view)))))])
          (eq-hashtable-set! %entries conn (cons (cons key entry) (eq-hashtable-ref %entries conn '())))
          entry))))

(define (%remove-doc-entries! conn b)
  (call-as-owner %self
    (lambda ()
      (buffers:with-buffer b
        (for-each (lambda (e) (hooks:remove-local! docs-at-point:sources (cdr e))) (eq-hashtable-ref %entries conn '()))))))


(buffers:define-layer %highlights (priority 5))

(define-record-type %lit (sealed #t) (fields buffer view))

(define %lit-now #f)

(define (%clear-highlights! . ignored)
  (let ([l %lit-now])
    (set! %lit-now #f)
    (when (and l (buffers:live? (%lit-buffer l)))
      (let ([b (%lit-buffer l)])
        (buffers:set-spans! (buffers:layer b %highlights (%lit-view l)) 0 (document:length (buffers:document b)) '())))))

(define (highlight view)
  (let* ([b (views:buffer view)] [conns (%give (%ordered-conns b) 'document-highlight b)])
    (when (pair? conns)
      (let* ([conn (car conns)] [version (buffers:version b)]
             [result (request (%conn-rpc conn) "textDocument/documentHighlight" (%point-params conn b (views:point view)))])
        (when (and (eqv? version (buffers:version b)) (pair? (%list result)))
          (%clear-highlights!)
          (let ([doc (buffers:document b)])
            (buffers:set-spans! (buffers:layer b %highlights view) 0 (document:length doc)
              (map (lambda (h) (let-values ([(s e) (%bounds-at doc (%ref h "range") (%conn-encoding conn))])
                                 (list s e (list (cons 'face (list 'lsp.highlight faces:highlight))))))
                   (%list result)))
            (set! %lit-now (make-%lit b view))))))))

(define %highlight-pending? #f)
(define %highlight-timer #f)
(define %highlight-timer-delay #f)

(define (%after-command command)
  (set! %highlight-pending? #t)
  (let ([delay (highlight-delay)])
    (unless (eqv? delay %highlight-timer-delay)
      (when %highlight-timer (timers:cancel! %highlight-timer))
      (set! %highlight-timer-delay delay)
      (set! %highlight-timer (call-as-owner %self (lambda () (timers:run-when-idle delay %on-idle)))))))

(define %symbol-kinds
  '#(file module namespace package class method property field constructor enum interface function variable constant
     string number boolean array object key null enum-member struct event operator type-parameter))

(define (%symbol-kind n)
  (if (and (fixnum? n) (fx<= 1 n (vector-length %symbol-kinds))) (vector-ref %symbol-kinds (fx- n 1)) 'unknown))

(define (%blank? s) (for-all char-whitespace? (string->list s)))

;; The protocol neither orders a symbol's children nor keeps them inside
;; its range, so a server's tree is sorted and repaired here rather than
;; refused: a child outside its parent joins the parent's level, and a
;; symbol overlapping the one before it at its level is left out.
(define (%symbol-entries conn doc symbols)
  (define (bounds r)
    (let-values ([(s e) (%bounds-at doc r (%conn-encoding conn))]) (values s (fxmax s e))))
  (define (convert symbol)
    (let ([name (%ref symbol "name")] [range (or (%ref symbol "range") (%ref symbol "location" "range"))])
      (if (and (string? name) (not (%blank? name)) range)
          (let*-values ([(start end) (bounds range)]
                        [(point) (let ([selection (%ref symbol "selectionRange")])
                                   (if selection (let-values ([(s e) (bounds selection)]) s) start))]
                        [(entry) (outline:make-entry name (%symbol-kind (%ref symbol "kind")) start end
                                                     (fxmax start (fxmin point end)))]
                        [(inside outside) (partition (lambda (child) (and (fx<= start (outline:entry-start child))
                                                                          (fx<= (outline:entry-end child) end)))
                                                     (level (%list (%ref symbol "children"))))])
            (cons (outline:make-parent entry inside) outside))
          '())))
  (define (level symbols)
    (let loop ([entries (list-sort (lambda (a b) (fx< (outline:entry-start a) (outline:entry-start b)))
                                   (apply append (map convert symbols)))]
               [kept '()])
      (cond
        [(null? entries) (reverse kept)]
        [(and (pair? kept) (fx< (outline:entry-start (car entries)) (outline:entry-end (car kept))))
         (loop (cdr entries) kept)]
        [else (loop (cdr entries) (cons (car entries) kept))])))
  (level symbols))

(define (outline-source b)
  (unless (buffers:buffer? b) (assertion-violation 'lsp:outline-source "not a buffer" b))
  (let ([conns (%give (%ordered-conns b) 'document-symbol b)])
    (and (pair? conns)
         (let ([conn (car conns)])
           (%flush! conn)
           (let* ([version (buffers:version b)]
                  [result (jsonrpc:request (%conn-rpc conn) "textDocument/documentSymbol"
                            `(("textDocument" . ,(%doc-identifier conn b))))]
                  [doc (and (buffers:live? b) (buffers:document-at b version))])
             (and doc (outline:make-outline b version (%symbol-entries conn doc (%list result)))))))))

(define (%forget-outlines rpc)
  (let ([conn (eq-hashtable-ref %by-rpc rpc #f)])
    (when conn
      (for-each (lambda (d) (when (buffers:live? (%doc-buffer d)) (outline:forget! (%doc-buffer d)))) (%conn-docs conn)))))

(define (%on-idle)
  (when %highlight-pending?
    (set! %highlight-pending? #f)
    (let ([view (layout:selected-view)])
      (when (and view (views:buffer view) (pair? (%conns-of (views:buffer view))))
        (spawn-task (lambda (restore) (guard (c [(not (cancelled? c)) (void)]) (highlight view))))))))


(define (%diagnostic-data b start end source)
  (filter values
    (map (lambda (d) (and (eq? (diagnostics:diagnostic-source d) source) (diagnostics:diagnostic-data d)))
         (diagnostics:in b start end))))

;; Each request waits, so a connection may end while another answers;
;; one that has gives nothing.
(define (%actions-at b start end kind trigger-kind)
  (apply append
    (map (lambda (conn)
           (if (not (%live? conn))
               '()
               (let* ([versions (%versions (list conn))]
                      [result (request (%conn-rpc conn) "textDocument/codeAction"
                                `(("textDocument" . ,(%doc-identifier conn b))
                                  ("range" . ,(%range-at (buffers:document b) start end (%conn-encoding conn)))
                                  ("context" ("diagnostics" . ,(list->vector (%diagnostic-data b start end (%conn-source conn))))
                                   ,@(if kind `(("only" . ,(vector kind))) '())
                                   ("triggerKind" . ,trigger-kind))))])
                 (map (lambda (a) (list conn a versions)) (%list result)))))
         (%give (%ordered-conns b) 'code-action b))))

(define (%action-label entry several?)
  (let ([title (or (%ref (cadr entry) "title") "")])
    (if several? (%fmt "~a (~a)" title (%conn-title (car entry))) title)))

(define (%preferred-first entries)
  (append (filter (lambda (e) (eq? (%ref (cadr e) "isPreferred") #t)) entries)
          (remp (lambda (e) (eq? (%ref (cadr e) "isPreferred") #t)) entries)))

(define (%run-action! entry)
  (let* ([conn (car entry)] [action (cadr entry)] [versions (caddr entry)]
         [action (if (and (not (%ref action "edit")) (string? (%ref action "title")) (not (string? (%ref action "command")))
                          (%ref (%conn-caps conn) "codeActionProvider" "resolveProvider"))
                     (or (jsonrpc:request (%conn-rpc conn) "codeAction/resolve" action) action)
                     action)])
    (if (string? (%ref action "command"))
        (execute-command (%conn-rpc conn) action)
        (begin
          (let ([edit (%ref action "edit")]) (when (pair? edit) (%apply-workspace-edit! conn edit versions)))
          (let ([command (%ref action "command")]) (when (pair? command) (execute-command (%conn-rpc conn) command)))))))

(define (%choose-and-run! entries who)
  (when (null? entries) (error who "No code actions here"))
  (let ([several? (fx> (length (%remove-duplicates (map car entries))) 1)] [entries (%preferred-first entries)])
    (%run-action! (if (null? (cdr entries))
                      (car entries)
                      (ask:choice "Code action: " (map (lambda (e) (cons (%action-label e several?) e)) entries))))))

(define (%remove-duplicates l) (fold-right (lambda (x acc) (if (memq x acc) acc (cons x acc))) '() l))

(define %hinted #f)

(define %action-kinds '("quickfix" "refactor.extract" "refactor.inline" "refactor.rewrite" "source.organizeImports"))

(define (%action-range)
  (let* ([event (keys:command-event)]
         [posn (and event (not (string? event)) (keys:event-end event))]
         [view (if posn (or (views:posn-view posn) (views:current)) (views:current))]
         [b (views:buffer view)]
         [p (or (and posn (views:posn-point posn)) (views:point view))]
         [mark (and (not posn) (views:mark view))])
    (cond
      [(and mark (not (fx= mark (views:point view)))) (values b (fxmin mark p) (fxmax mark p))]
      [(pair? (diagnostics:in b p))
       (let ([ds (diagnostics:in b p)])
         (values b (apply min (map diagnostics:diagnostic-start ds)) (apply max (map diagnostics:diagnostic-end ds))))]
      [else
       (let-values ([(s e) (guard (c [(not (cancelled? c)) (values #f #f)]) (syntax:symbol-bounds b p))])
         (if s (values b s e) (values b p p)))])))

(commands:define-command (code-actions [start #f] [end #f] [kind (and (commands:prefix-argument) (ask:line-with-candidates "Action kind: " %action-kinds))])
  "Runs a code action from START to END, by default the region, else the diagnostics at point or at the click, else the symbol at point, chosen among every connection's; with C-u, of a kind asked for."
  (let-values ([(b s e) (if start (values (buffers:current) start (or end start)) (%action-range))])
    (let ([kind (and kind (not (equal? kind "")) kind)])
      (let ([hinted %hinted])
        (if (and hinted (not kind) (eq? (car hinted) b) (eqv? (cadr hinted) (buffers:version b)) (eqv? (caddr hinted) s))
            (%run-action! (cadddr hinted))
            (%choose-and-run! (%actions-at b s e kind 1) 'lsp:code-actions))))))

(define (%run-kind! who kind whole?)
  (let* ([view (views:current)] [b (views:buffer view)] [doc (buffers:document b)]
         [p (views:point view)]
         [entries (if whole?
                      (%actions-at b (%content-start doc) (%content-end doc) kind 1)
                      (let-values ([(b s e) (%action-range)]) (%actions-at b s e kind 1)))]
         [entries (filter (lambda (e) (let ([k (%ref (cadr e) "kind")]) (or (not (string? k)) (string=? k kind)
                                                                            (and (> (string-length k) (string-length kind))
                                                                                 (string=? (substring k 0 (string-length kind)) kind)))))
                          entries)])
    (%choose-and-run! entries who)))

(commands:define-command (organize-imports)
  "Runs the code action of kind source.organizeImports, without asking when there is one."
  (%run-kind! 'lsp:organize-imports "source.organizeImports" #t))

(commands:define-command (quickfix)
  "Runs a code action of kind quickfix at point, without asking when there is one."
  (%run-kind! 'lsp:quickfix "quickfix" #f))

(define (code-action-hint view)
  (and (code-action-hint?)
       (guard (c [(and (not (cancelled? c)) (or (jsonrpc:ended? c) (jsonrpc:timeout? c))) #f])
         (%code-action-hint view))))

(define (%code-action-hint view)
  (let* ([b (views:buffer view)] [p (views:point view)] [ds (diagnostics:in b p)])
    (and (pair? ds)
         (let* ([s (apply min (map diagnostics:diagnostic-start ds))] [e (apply max (map diagnostics:diagnostic-end ds))]
                [entries (%preferred-first (%actions-at b s e #f 2))])
           (and (pair? entries)
                (let ([key (let ([keys (filter (lambda (k) (not (char=? (string-ref k 0) #\<))) (keys:where-is #f code-actions))])
                             (if (pair? keys) (car keys) "M-x lsp:code-actions"))])
                  (set! %hinted (and (null? (cdr entries)) (list b (buffers:version b) s (car entries))))
                  (docs-at-point:make-doc
                    (if (null? (cdr entries))
                        (%fmt "~a (~a)" (%ref (cadar entries) "title") key)
                        (%fmt "~a code actions (~a)" (length entries) key)))))))))


(define (%rename-default)
  (let* ([view (views:current)] [b (views:buffer view)] [conns (%give (%ordered-conns b) 'rename b)])
    (when (null? conns) (error 'lsp:rename "No server renames here"))
    (let* ([conn (car conns)]
           [prepare? (%ref (%conn-caps conn) "renameProvider" "prepareProvider")]
           [prepared (and prepare? (request (%conn-rpc conn) "textDocument/prepareRename" (%point-params conn b (views:point view))))]
           [default (cond
                      [(and (pair? prepared) (string? (%ref prepared "placeholder"))) (%ref prepared "placeholder")]
                      [(and (pair? prepared) (pair? (%ref prepared "start")))
                       (let-values ([(s e) (%bounds-at (buffers:document b) prepared (%conn-encoding conn))])
                         (buffers:text-between (buffers:document b) s e))]
                      [else (or (%identifier-at view) "")])])
      (when (and prepare? (not (pair? prepared)))
        (error 'lsp:rename "Can't rename here"))
      (ask:line (%fmt "Rename `~a' to: " default) default))))

(commands:define-command (rename [name (%rename-default)])
  "Renames the identifier at point to NAME across the project."
  (let* ([view (views:current)] [b (views:buffer view)] [conns (%give (%ordered-conns b) 'rename b)])
    (when (null? conns) (error 'lsp:rename "No server renames here"))
    (let* ([conn (car conns)] [versions (%versions (list conn))]
           [edit (request (%conn-rpc conn) "textDocument/rename" (append (%point-params conn b (views:point view)) `(("newName" . ,name))))])
      (%apply-workspace-edit! conn edit versions))))

(define (%formatting-options) '(("tabSize" . 8) ("insertSpaces" . #t)))

(define (%format! b start end who)
  (let* ([ranged? (and start (fx< start end))]
         [conns (%give (%ordered-conns b) (if ranged? 'range-formatting 'formatting) b)])
    (when (null? conns) (error who "No server formats here"))
    (let* ([conn (car conns)] [version (begin (%flush! conn) (buffers:version b))]
           [edits (if ranged?
                      (jsonrpc:request (%conn-rpc conn) "textDocument/rangeFormatting"
                        `(("textDocument" . ,(%doc-identifier conn b))
                          ("range" . ,(%range-at (buffers:document b) start end (%conn-encoding conn)))
                          ("options" . ,(%formatting-options))))
                      (jsonrpc:request (%conn-rpc conn) "textDocument/formatting"
                        `(("textDocument" . ,(%doc-identifier conn b)) ("options" . ,(%formatting-options)))))])
      (%apply-text-edits! conn b (%list edits) version))))

(commands:define-command (format)
  "Formats the region, or the buffer when there is none, with the first connection that gives formatting."
  (let* ([view (views:current)] [b (views:buffer view)] [mark (views:mark view)] [p (views:point view)])
    (if (and mark (not (fx= mark p)))
        (%format! b (fxmin mark p) (fxmax mark p) 'lsp:format)
        (%format! b #f #f 'lsp:format))))

(commands:define-command (format-buffer [b (buffers:current)])
  "Formats the buffer B with the first connection that gives formatting."
  (%format! b #f #f 'lsp:format-buffer))

(define (%on-type-format! b edit inserted)
  (when (and (fx= (string-length inserted) 1) (buffers:with-buffer b (on-type-formatting?)))
    (let ([c (string-ref inserted 0)])
      (for-each
        (lambda (conn)
          (let* ([provider (%ref (%conn-caps conn) "documentOnTypeFormattingProvider")]
                 [triggers (and (pair? provider) (cons (%ref provider "firstTriggerCharacter") (%list (%ref provider "moreTriggerCharacter"))))])
            (when (and triggers (member (string c) triggers))
              (let ([p (fx+ (buffers:edit-start edit) 1)] [version (buffers:version b)])
                (call-as-owner %self
                  (lambda ()
                    (spawn-task
                      (lambda (restore)
                        (guard (e [(not (cancelled? e)) (void)])
                          (%flush! conn)
                          ;; Edits made after the typed character, such as the
                          ;; same command's indentation, move the position the
                          ;; request would name, and any answer would be dropped.
                          (when (eqv? version (buffers:version b))
                            (let ([edits (jsonrpc:request (%conn-rpc conn) "textDocument/onTypeFormatting"
                                           (append (%point-params conn b p) `(("ch" . ,(string c)) ("options" . ,(%formatting-options)))))])
                              (%apply-text-edits! conn b (%list edits) version))))))))))))
        (let ([first (%give (%ordered-conns b) 'on-type-formatting b)]) (if (pair? first) (list (car first)) '()))))))


(define (show-status view)
  (let ([b (views:buffer view)])
    (and b
         (let ([conns (%ordered-conns b)])
           (and (pair? conns)
                (haml (:span.lsp-status
                        (map (lambda (conn)
                               (let ([progress (and (report-progress?) (%conn-progress conn))])
                                 (string-append
                                   (%conn-title conn)
                                   (if progress
                                       (%fmt " ~a~a" (car progress) (if (number? (cadr progress)) (%fmt " ~a%" (cadr progress)) ""))
                                       "")
                                   (if (%conn-error conn) " !" "")
                                   " ")))
                             conns))))))))

(tables:define-table %status-keymap "Clicks on the language servers' status.")

(commands:define-command (%show-clicked-events [event (keys:command-event)])
  "Shows the events log of the first connection of the clicked window's buffer."
  (let* ([view (layout:part-view (views:posn-node (keys:event-end event)))] [conns (%ordered-conns (views:buffer view))])
    (when (pair? conns)
      (let ([conn (car conns)])
        (when (%conn-error conn)
          (ask:message (%conn-error conn))
          (%conn-error-set! conn #f))
        (layout:display-buffer (jsonrpc:events-buffer (%conn-rpc conn)))))))

(status-line:define-segment status (show show-status) (keymap %status-keymap))


(define-server rust-analyzer '("rust-analyzer"))
(define-server neocmakelsp '("neocmakelsp" "stdio"))
(define-server cmake-language-server '("cmake-language-server"))
(define-server vim-language-server '("vim-language-server" "--stdio"))
(define-server rass-python '("rass" "python"))
;; A Python project often has no repository, and these servers find its
;; settings and environment from the root. Each list is nvim-lspconfig's,
;; in its priority order; it leaves out .git, which projects:find gives
;; with its rules for submodules.
(define-server pylsp '("pylsp") (root '("pyproject.toml" "setup.py" "setup.cfg" "requirements.txt" "Pipfile")))
(define-server pyls '("pyls"))
(define-server basedpyright '("basedpyright-langserver" "--stdio")
  (root '("pyrightconfig.json" "pyproject.toml" "setup.py" "setup.cfg" "requirements.txt" "Pipfile")))
(define-server pyright '("pyright-langserver" "--stdio")
  (root '("pyrightconfig.json" "pyproject.toml" "setup.py" "setup.cfg" "requirements.txt" "Pipfile")))
(define-server pyrefly '("pyrefly" "lsp")
  (root '("pyrefly.toml" "pyproject.toml" "setup.py" "setup.cfg" "requirements.txt" "Pipfile")))
(define-server ty '("ty" "server") (root '("ty.toml" "pyproject.toml" "setup.py" "setup.cfg" "requirements.txt")))
(define-server jedi-language-server '("jedi-language-server")
  (root '("pyproject.toml" "setup.py" "setup.cfg" "requirements.txt" "Pipfile")))
(define-server ruff '("ruff" "server") (root '("pyproject.toml" "ruff.toml" ".ruff.toml")))
(define-server ruff-lsp '("ruff-lsp") (root '("pyproject.toml" "ruff.toml")))
(define-server vscode-json-language-server '("vscode-json-language-server" "--stdio"))
(define-server vscode-json-languageserver '("vscode-json-languageserver" "--stdio"))
(define-server json-languageserver '("json-languageserver" "--stdio"))
(define-server rass-ts '("rass" "ts"))
(define-server typescript-language-server '("typescript-language-server" "--stdio"))
(define-server bash-language-server '("bash-language-server" "start"))
(define-server phpactor '("phpactor" "language-server"))
(define-server php-language-server '("php" "vendor/felixfbecker/language-server/bin/php-language-server.php"))
(define-server clangd '("clangd"))
(define-server ccls '("ccls"))
(define-server ocamllsp '("ocamllsp"))
(define-server ruby-lsp '("ruby-lsp"))
(define-server haskell-language-server '("haskell-language-server-wrapper" "--lsp"))
(define-server static-ls '("static-ls"))
(define-server elm-language-server '("elm-language-server"))
(define-server mint '("mint" "ls"))
(define-server kotlin-language-server '("kotlin-language-server"))
(define-server gopls '("gopls"))
(define-server r-languageserver '("R" "--slave" "-e" "languageserver::run()"))
(define-server jdtls '("jdtls"))
(define-server java-language-server '("java-language-server"))
(define-server dart '("dart" "language-server" "--client-id" "tuna.lsp-dart"))
(define-server elixir-ls '("language_server.sh"))
(define-server lexical '("start_lexical.sh"))
(define-server ada-language-server '("ada_language_server"))
(define-server ada-language-server-gpr '("ada_language_server" "--language-gpr"))
(define-server metals '("metals"))
(define-server metals-emacs '("metals-emacs"))
(define-server racket-langserver '("racket" "-l" "racket-langserver"))
(define-server digestif '("digestif"))
(define-server texlab '("texlab"))
(define-server elp '("elp" "server"))
(define-server wat-server '("wat_server"))
(define-server yaml-language-server '("yaml-language-server" "--stdio"))
(define-server tombi '("tombi" "lsp"))
(define-server nil-ls '("nil"))
(define-server rnix-lsp '("rnix-lsp"))
(define-server nixd '("nixd"))
(define-server nls '("nls"))
(define-server nu '("nu" "--lsp"))
(define-server fennel-ls '("fennel-ls"))
(define-server move-analyzer '("move-analyzer"))
(define-server fortls '("fortls"))
(define-server futhark '("futhark" "lsp"))
(define-server lua-language-server '("lua-language-server"))
(define-server lua-lsp '("lua-lsp"))
(define-server yang-language-server '("yang-language-server"))
(define-server zls '("zls"))
(define-server vscode-css-language-server '("vscode-css-language-server" "--stdio"))
(define-server css-languageserver '("css-languageserver" "--stdio"))
(define-server vscode-html-language-server '("vscode-html-language-server" "--stdio"))
(define-server html-languageserver '("html-languageserver" "--stdio"))
(define-server docker-langserver '("docker-langserver" "--stdio"))
(define-server clojure-lsp '("clojure-lsp"))
(define-server omnisharp '("omnisharp" "-lsp"))
(define-server omnisharp-mixed-case '("OmniSharp" "-lsp"))
(define-server csharp-ls '("csharp-ls"))
(define-server purescript-language-server '("purescript-language-server" "--stdio"))
(define-server perl-language-server '("perl" "-MPerl::LanguageServer" "-e" "Perl::LanguageServer::run"))
(define-server marksman '("marksman" "server"))
(define-server vscode-markdown-language-server '("vscode-markdown-language-server" "--stdio"))
(define-server dot-language-server '("dot-language-server" "--stdio"))
(define-server terraform-ls '("terraform-ls" "serve"))
(define-server uiua '("uiua" "lsp"))
(define-server millet (lambda (root) (if root (list "millet-ls" root) (list "millet-ls"))))
(define-server blueprint-compiler '("blueprint-compiler" "lsp"))
(define-server ols '("ols"))

(for-each
  (lambda (entry) (tables:set! language-servers (car entry) (cdr entry)))
  `(("rust" ,rust-analyzer)
    ("cmake" (,neocmakelsp ,cmake-language-server))
    ("vim" ,vim-language-server)
    ("python" (,rass-python ,pylsp ,pyls ,basedpyright ,pyright ,pyrefly ,ty ,jedi-language-server ,ruff ,ruff-lsp))
    ("json" (,vscode-json-language-server ,vscode-json-languageserver ,json-languageserver))
    ("jsonc" (,vscode-json-language-server ,vscode-json-languageserver ,json-languageserver))
    ("javascript" (,rass-ts ,typescript-language-server))
    ("javascriptreact" (,rass-ts ,typescript-language-server))
    ("typescript" (,rass-ts ,typescript-language-server))
    ("typescriptreact" (,rass-ts ,typescript-language-server))
    ("shellscript" ,bash-language-server)
    ("php" (,phpactor ,php-language-server))
    ("c" (,clangd ,ccls))
    ("cpp" (,clangd ,ccls))
    ("objective-c" (,clangd ,ccls))
    ("ocaml" ,ocamllsp)
    ("reason" ,ocamllsp)
    ("ruby" ,ruby-lsp)
    ("haskell" (,haskell-language-server ,static-ls))
    ("elm" ,elm-language-server)
    ("mint" ,mint)
    ("kotlin" ,kotlin-language-server)
    ("go" ,gopls)
    ("go.mod" ,gopls)
    ("go.work" ,gopls)
    ("r" ,r-languageserver)
    ("java" (,jdtls ,java-language-server))
    ("dart" ,dart)
    ("elixir" (,elixir-ls ,lexical))
    ("heex" (,elixir-ls ,lexical))
    ("ada" ,ada-language-server)
    ("gpr" ,ada-language-server-gpr)
    ("scala" (,metals ,metals-emacs))
    ("racket" ,racket-langserver)
    ("latex" (,digestif ,texlab))
    ("tex" (,digestif ,texlab))
    ("context" (,digestif ,texlab))
    ("texinfo" (,digestif ,texlab))
    ("bibtex" (,digestif ,texlab))
    ("erlang" ,elp)
    ("wat" ,wat-server)
    ("yaml" ,yaml-language-server)
    ("toml" ,tombi)
    ("nix" (,nil-ls ,rnix-lsp ,nixd))
    ("nickel" ,nls)
    ("nushell" ,nu)
    ("fennel" ,fennel-ls)
    ("move" ,move-analyzer)
    ("fortran" ,fortls)
    ("futhark" ,futhark)
    ("lua" (,lua-language-server ,lua-lsp))
    ("yang" ,yang-language-server)
    ("zig" ,zls)
    ("css" (,vscode-css-language-server ,css-languageserver))
    ("html" (,vscode-html-language-server ,html-languageserver))
    ("dockerfile" ,docker-langserver)
    ("clojure" ,clojure-lsp)
    ("clojurescript" ,clojure-lsp)
    ("csharp" (,omnisharp ,omnisharp-mixed-case ,csharp-ls))
    ("purescript" ,purescript-language-server)
    ("perl" ,perl-language-server)
    ("markdown" (,marksman ,vscode-markdown-language-server))
    ("dot" ,dot-language-server)
    ("terraform" ,terraform-ls)
    ("uiua" ,uiua)
    ("sml" ,millet)
    ("blueprint" ,blueprint-compiler)
    ("odin" ,ols)))


(tables:set! request-handlers "workspace/configuration" %configuration-request)
(tables:set! request-handlers "workspace/applyEdit" %apply-edit-request)
(tables:set! request-handlers "workspace/workspaceFolders"
  (lambda (rpc params) (%workspace-folders (%conn-root (eq-hashtable-ref %by-rpc rpc #f)))))
(tables:set! request-handlers "window/showMessageRequest" %show-message-request)
(tables:set! request-handlers "window/showDocument" %show-document)
(tables:set! request-handlers "window/workDoneProgress/create" %nothing)
(tables:set! request-handlers "client/registerCapability" %nothing)
(tables:set! request-handlers "client/unregisterCapability" %nothing)
(for-each (lambda (method) (tables:set! request-handlers method %nothing))
          '("workspace/diagnostic/refresh" "workspace/semanticTokens/refresh" "workspace/inlayHint/refresh"
            "workspace/codeLens/refresh" "workspace/inlineValue/refresh" "workspace/foldingRange/refresh"))

(tables:set! notification-handlers "textDocument/publishDiagnostics"
  (lambda (rpc params) (%on-publish (eq-hashtable-ref %by-rpc rpc #f) params)))
(tables:set! notification-handlers "window/showMessage"
  (lambda (rpc params) (ask:message (%titled-message rpc params))))
(tables:set! notification-handlers "window/logMessage" (lambda (rpc params) (void)))
(tables:set! notification-handlers "$/progress" %progress)

(keys:bind! diagnostic-keymap "<mouse-2>" code-actions)
(keys:bind! %status-keymap "<mouse-1>" %show-clicked-events)
(tables:set! status-line:segments status (status-line:right 30))
(hooks:add! buffers:killed %killed)
(hooks:add! modes:major-mode-changed %mode-changed)
(hooks:add! views:drawn-ranges-changed %ensure-when-drawn)
(hooks:add! outline:sources outline-source -10)
(hooks:add! managed outline:forget!)
(hooks:add! connected %forget-outlines)
(hooks:add! files:after-rename %renamed)
(hooks:add! files:before-save %will-save)
(hooks:add! files:after-save %did-save)
(hooks:add! commands:before-command %clear-highlights!)
(hooks:add! commands:after-command %after-command)
(on-unload (lambda () (for-each (lambda (conn) (%conn-shutting-down?-set! conn #t)) %connections)))
