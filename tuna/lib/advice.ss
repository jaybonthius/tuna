;;; Module-wide function composition; receipts own contributions, not scope.
prelude: :gerbil/core

(import :std/error
        :std/list/list
        (only-in :gerbil/expander import-module current-expander-context)
        :tuna/kernel)
(export open-function new-open-function open-function-base open-function-effective
        replace-open-function! resolve-open-function
        register-function-advice! remove-function-advice!
        inspect-function-advice advised-functions compose-advice refresh-function-advice!
        advice-info advice-info-owner advice-info-name advice-info-kind
        advice-info-depth advice-info-source
        function-advice-info function-advice-info-name function-advice-info-source
        function-advice-info-advice
        advice-error?)

(deferror-class AdviceError () advice-error?)

;; Only read accessors are public. CTX and CALLBACK are installation details.
(defstruct advice-info ((owner : :symbol) (name : :symbol) (kind : :symbol)
                       (depth : :fixnum) (source :? :string)
                       (ctx : context) (callback : :procedure))
  final: #t)
(defstruct function-advice-info ((name : :symbol) (source :? :string) (advice : :list))
  final: #t)
(defstruct advice-owner ((records : :list)) final: #t)
(defstruct open-function ((base : :procedure) (effective : :procedure)
                         (name : :symbol) (source :? :string) (owners : entry-table)
                         (advice : :list))
  final: #t)

;; Only advised cells are enumerable; ordinary open functions are not registered.
(def advised-cells [])

(def (new-open-function (base : :procedure) (name : :symbol) (source :? :string)) => open-function
  (make-open-function base base name source (new-entry-table) []))

(def (ordered-advice (cell : open-function)) => :list
  ;; Earlier declarations are outermost; names break ties within one owner.
  ;; All ordering work happens on changes, never on function calls.
  (let* ((entries (reverse (entry-table-entries cell.owners 'advice)))
         (owners (map entry-owner entries)))
    (list-sort
     (lambda ((a : advice-info) (b : advice-info))
       (or (fx< a.depth b.depth)
           (and (fx= a.depth b.depth)
                (if (eq? a.owner b.owner)
                  (string<? (symbol->string a.name) (symbol->string b.name))
                  (and (memq b.owner (cdr (memq a.owner owners))) #t)))))
     (append-map (lambda ((e : entry))
                   (advice-owner-records (: (entry-value e) advice-owner)))
                 entries))))

(def (inspect-function-advice (cell : open-function)) => function-advice-info
  ;; Inspection describes the installed chain, even between rank updates and refresh.
  (make-function-advice-info cell.name cell.source cell.advice))

(def (advised-functions) => :list
  (map inspect-function-advice advised-cells))

(def (refresh-open-function! (cell : open-function)) => :void
  (let (records (ordered-advice cell))
    (set! cell.effective (compose-advice cell.base records))
    (set! cell.advice records)
    (set! advised-cells
      (if (null? records) (remq cell advised-cells)
          (if (memq cell advised-cells) advised-cells (cons cell advised-cells))))))

;; Configuration calls this once after a batch of owner declaration-rank updates.
(def (refresh-function-advice!) => :void
  (for-each refresh-open-function! advised-cells))

(def (replace-open-function! (cell : open-function) (replacement : :procedure)) => :void
  (set! cell.base replacement)
  (refresh-open-function! cell))

(def (resolve-open-function (module : :t) (name : :symbol)) => open-function
  ;; The documented enter! path uses the existing module instance, never reloads.
  (parameterize ((current-expander-context (import-module module #f #t)))
    (: (eval (list 'open-function-cell name)) open-function)))

(def (find-advice-owner (cell : open-function) (ctx : context)) => (Maybe advice-owner)
  (let (found (find (lambda ((e : entry))
                     (eq? (entry-owner e) (context-plugin-name ctx)))
                   (entry-table-entries cell.owners 'advice)))
    (and found (: (entry-value found) advice-owner))))

(def (register-function-advice! (ctx : context) (cell : open-function)
                                (name : :symbol) (kind : :symbol) (callback : :procedure)
                                depth: (depth : :fixnum := 0)
                                source: (source :? :string := #f)) => :void
  (unless (memq kind '(before after around override filter-args filter-return
                      before-while before-until after-while after-until))
    (error "Unknown advice kind" kind))
  (let* ((bucket (or (find-advice-owner cell ctx)
                     (let (new (make-advice-owner []))
                       ;; Receipt order matters: remove the entry, then recompose.
                       ;; One pair per owner/target; replacements add no inverses.
                       (context-defer! ctx (lambda () (refresh-open-function! cell)))
                       (context-add-entry! ctx cell.owners 'advice new)
                       new)))
         (record (make-advice-info (context-plugin-name ctx) name kind depth source ctx callback)))
    (set! (advice-owner-records bucket)
      (cons record (filter (lambda ((old : advice-info)) (not (eq? old.name name)))
                           (advice-owner-records bucket))))
    (refresh-open-function! cell)))

(def (remove-function-advice! (ctx : context) (cell : open-function) (name : :symbol)) => :void
  (let (bucket (find-advice-owner cell ctx))
    (when bucket
      (set! (advice-owner-records bucket)
        (filter (lambda ((old : advice-info)) (not (eq? old.name name)))
                (advice-owner-records bucket)))
      (refresh-open-function! cell))))

(def (raise-advice-failure (record : advice-info) (cause : :t)) => :void
  (raise (AdviceError "Advice failed (owner, name, cause)"
                      irritants: [record.owner record.name cause] where: 'advise!)))

;; Catch only callback failures, never normal-return continuations or the base.
(def (call-advice (record : advice-info) (args : :list)) => :values
  (with-catch
   (lambda (e) (if (quit-condition? e) (raise e) (raise-advice-failure record e)))
   (lambda ()
     (call-with-context record.ctx (lambda () (apply record.callback args))))))

(def (call-advice-predicate (record : advice-info) (args : :list)) => :t
  (call-with-values (lambda () (call-advice record args))
    (lambda results
      (unless (and (pair? results) (null? (cdr results)))
        (raise-advice-failure record "Predicate advice must return exactly one value"))
      (car results))))

(def (compose-layer (record : advice-info) (inner : :procedure)) => :procedure
  (case record.kind
    ((before)
     (lambda args
       (call-with-values (lambda () (call-advice record args))
         (lambda ignored (apply inner args)))))
    ((after)
     (lambda args
       (call-with-values (lambda () (apply inner args))
         (lambda results
           (call-with-values (lambda () (call-advice record args))
             (lambda ignored (apply values results)))))))
    ((around)
     (lambda args
       (let ((caller (current-context)) (inner-failures []))
         (with-catch
          (lambda (e)
            (if (or (quit-condition? e) (memq e inner-failures))
              (raise e) (raise-advice-failure record e)))
          (lambda ()
            (call-with-context record.ctx
              (lambda ()
                (apply record.callback
                  (lambda original-args
                    (with-catch
                     (lambda (e) (set! inner-failures (cons e inner-failures)) (raise e))
                     (lambda ()
                       ;; ORIGINAL retains the caller's registration context and task.
                       (call-with-context caller (lambda () (apply inner original-args))))))
                  args))))))))
    ((override) (lambda args (call-advice record args)))
    ((filter-args)
     (lambda args
       (let (filtered (call-advice-predicate record [args]))
         (unless (list? filtered)
           (raise-advice-failure record "filter-args must return one argument list"))
         (apply inner filtered))))
    ((filter-return)
     ;; Each returned value becomes one callback argument; any output arity is valid.
     (lambda args
       (call-with-values (lambda () (apply inner args))
         (lambda results (call-advice record results)))))
    ((before-while before-until)
     ;; The callback is a single-value predicate; the selected inner result is unrestricted.
     (lambda args
       (let (result (call-advice-predicate record args))
         (if (if (eq? record.kind 'before-while) result (not result))
           (apply inner args) result))))
    ((after-while after-until)
     ;; INNER is a single-value predicate; the selected callback result is unrestricted.
     (lambda args
       (call-with-values (lambda () (apply inner args))
         (lambda results
           (unless (and (pair? results) (null? (cdr results)))
             (error "Conditional advice requires exactly one inner value" record.kind))
           (let (result (car results))
             (if (if (eq? record.kind 'after-while) result (not result))
               (call-advice record args) result))))))
    (else (error "Unknown advice kind" record.kind))))

;; RECORDS are outermost first. An empty chain is exactly BASE, not a wrapper.
(def (compose-advice (base : :procedure) (records : :list)) => :procedure
  (foldr (lambda ((record : advice-info) (inner : :procedure))
           (compose-layer record inner))
         base records))
