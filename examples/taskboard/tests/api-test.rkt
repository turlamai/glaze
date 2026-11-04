#lang racket/base

;; Windowless integration test for the Taskboard example: the real typed
;; routes, the real store and the generated JavaScript client, against a
;; disposable data directory and a loopback server.

(require json
         net/http-client
         racket/file
         racket/list
         racket/port
         racket/runtime-path
         racket/string
         rackunit
         glaze/server)

(define-runtime-path main-module "../main.rkt")

(define data-root (make-temporary-file "taskboard-api-~a" 'directory))
(void (putenv "TASKBOARD_DATA_DIR" (path->string data-root)))

(define api (dynamic-require main-module 'api))
(define bus (dynamic-require main-module 'bus))
(define public (dynamic-require main-module 'public))

(define token "taskboard-test-token")

(define (start)
  (let loop ([attempt 0])
    (define candidate (+ 20000 (random 45000)))
    (with-handlers ([exn:fail:network? (lambda (error)
                                         (if (< attempt 40)
                                             (loop (add1 attempt))
                                             (raise error)))])
      (start-server #:port candidate #:public-dir public #:api api #:events bus #:api-token token))))

(define-values (port shutdown) (start))

(define (status-text status)
  (bytes->string/utf-8 status))
(define (ok? status)
  (string-contains? (status-text status) "200"))

(define (call method path [data #f] #:token [use-token? #t])
  (define headers
    (append (if use-token?
                (list (string-append "X-Glaze-Token: " token))
                '())
            (if data
                (list "Content-Type: application/json")
                '())))
  (define-values (status _headers input)
    (if data
        (http-sendrecv "127.0.0.1" path #:port port #:method method #:data data #:headers headers)
        (http-sendrecv "127.0.0.1" path #:port port #:method method #:headers headers)))
  (define body (port->string input))
  (close-input-port input)
  (values status body))

(define (body-json body)
  (read-json (open-input-string body)))

(void (dynamic-wind
       void
       (lambda ()
         ;; The generated client must expose the routes as typed calls.
         (define-values (client-status client-body) (call "GET" "/glaze/api.js" #:token #f))
         (check-true (ok? client-status))
         (for ([name (in-list '("tasksCreate" "tasksToggle" "tasksDelete" "tasksClearDone"))])
           (check-true (string-contains? client-body name)
                       (format "generated client exposes ~a" name)))

         ;; A missing token is rejected before any handler runs.
         (define-values (unauthenticated-status _) (call "GET" "/api/tasks" #:token #f))
         (check-false (ok? unauthenticated-status))

         ;; Empty board.
         (define-values (empty-status empty-body) (call "GET" "/api/tasks"))
         (check-true (ok? empty-status))
         (check-equal? (hash-ref (body-json empty-body) 'tasks) '())

         ;; Create, list, toggle, delete.
         (define-values (create-status create-body)
           (call "POST" "/api/tasks/create" (jsexpr->string (hasheq 'title "Write the example"))))
         (check-true (ok? create-status))
         (define created (body-json create-body))
         (check-equal? (length (hash-ref created 'tasks)) 1)
         (check-equal? (hash-ref (hash-ref created 'stats) 'open) 1)
         (define task (first (hash-ref created 'tasks)))
         (define id (hash-ref task 'id))

         (define-values (toggle-status toggle-body)
           (call "POST" "/api/tasks/toggle" (jsexpr->string (hasheq 'id id))))
         (check-true (ok? toggle-status))
         (check-true (hash-ref (first (hash-ref (body-json toggle-body) 'tasks)) 'done))
         (check-equal? (hash-ref (hash-ref (body-json toggle-body) 'stats) 'done) 1)

         (define-values (delete-status delete-body)
           (call "POST" "/api/tasks/delete" (jsexpr->string (hasheq 'id id))))
         (check-true (ok? delete-status))
         (check-equal? (hash-ref (body-json delete-body) 'tasks) '())

         ;; Concurrent creates all persist: the route layer serializes
         ;; read-modify-write and the store is initialized once.
         (define workers
           (for/list ([index (in-range 8)])
             (thread (lambda ()
                       (call "POST"
                             "/api/tasks/create"
                             (jsexpr->string (hasheq 'title (format "parallel ~a" index))))))))
         (for-each thread-wait workers)
         (define-values (concurrent-status concurrent-body) (call "GET" "/api/tasks"))
         (check-true (ok? concurrent-status))
         (define concurrent-tasks (hash-ref (body-json concurrent-body) 'tasks))
         (check-equal? (length concurrent-tasks) 8)
         (check-equal? (length (remove-duplicates (map (lambda (task) (hash-ref task 'id))
                                                       concurrent-tasks)))
                       8)

         ;; Invalid input is a 400, not a 500.
         (define-values (bad-status _bad-body)
           (call "POST" "/api/tasks/create" (jsexpr->string (hasheq 'title "   "))))
         (check-true (string-contains? (status-text bad-status) "400")))
       (lambda ()
         (shutdown)
         (when (directory-exists? data-root)
           (delete-directory/files data-root)))))
