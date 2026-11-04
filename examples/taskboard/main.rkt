#lang racket/base

;; Taskboard: a maintained product-level Glaze example.
;;
;; One typed route declaration produces the Racket procedures, the HTTP
;; routes and the generated JavaScript client. Tasks live in a Glaze store
;; under the application data directory; the page never sees a path or a
;; token. The bus pushes a fresh snapshot after every mutation so two
;; windows (or a reloaded page) stay consistent.

(require racket/file
         racket/runtime-path
         glaze
         "taskboard.rkt")

(define-runtime-path public "public")

(define taskboard-app-id "com.turlamai.taskboard")
(define paths (make-path-resolver taskboard-app-id))
(define bus (make-event-bus))
(define state-lock (make-semaphore 1))
(define store-box (box #f))

;; Tests and CI point TASKBOARD_DATA_DIR at a disposable directory; the
;; shipped app uses the per-user application data directory.
(define (data-root)
  (or (getenv "TASKBOARD_DATA_DIR") (app-data-dir paths)))

;; The store is created on first use, not at module load: `raco glaze schema
;; check` and `raco glaze inspect` load this module and must not touch user
;; data or create directories.
(define (task-store)
  (or (unbox store-box)
      (let* ([data-dir (data-root)]
             [_ (make-directory* data-dir)]
             [store (load-store (build-path data-dir "tasks.json")
                                #:defaults (hasheq 'tasks '())
                                #:auto-save 100)])
        (set-box! store-box store)
        store)))

(define (tasks)
  (define stored (store-get (task-store) 'tasks '()))
  (cond
    [(task-list? stored) stored]
    ;; Never overwrite a file we cannot understand: report it and leave the
    ;; data for the user to inspect or repair.
    [else (error 'taskboard "tasks.json does not contain a valid task list")]))

(define (snapshot-of current)
  (hasheq 'tasks current 'stats (task-stats current)))

(define (snapshot)
  (snapshot-of (tasks)))

(define (notify! snapshot)
  (bus-broadcast! bus 'tasks-changed snapshot))

(define (invalid! message)
  (raise (exn:fail:glaze:bad-param message (current-continuation-marks))))

;; Serialize read-modify-write so two concurrent requests cannot lose an
;; update. Returns the fresh snapshot, or #f when `update` rejects the input.
(define (mutate! update)
  (call-with-semaphore state-lock
                       (lambda ()
                         (define after (update (tasks)))
                         (and after
                              (let ([fresh (snapshot-of after)])
                                (store-set! (task-store) 'tasks after)
                                (notify! fresh)
                                fresh)))))

(define-api-routes api
                   [(GET "api/tasks") (listTasks) (snapshot)]
                   [(POST "api/tasks/create")
                    (createTask [title GString ""])
                    (or (mutate! (lambda (current) (task-add current title (current-seconds))))
                        (invalid! "title must be 1-120 characters and not blank"))]
                   [(POST "api/tasks/toggle")
                    (toggleTask [id GInt64 0])
                    (mutate! (lambda (current) (task-toggle current id)))]
                   [(POST "api/tasks/delete")
                    (deleteTask [id GInt64 0])
                    (mutate! (lambda (current) (task-remove current id)))]
                   [(POST "api/tasks/clear-done") (clearDone) (mutate! task-clear-done)])

(module+ main
  (run-app #:public-dir public
           #:api api
           #:events bus
           #:title "Taskboard"
           #:width 1000
           #:height 720
           #:app-id taskboard-app-id
           #:window-state #t))

(provide api
         bus
         taskboard-app-id
         public)
