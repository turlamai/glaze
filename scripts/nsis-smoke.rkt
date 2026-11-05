#lang racket/base

;; Windows-only NSIS fallback smoke. Generates the same script the build uses,
;; compiles it with makensis, silently installs, checks the payload and
;; uninstall entry, then silently uninstalls and checks they are gone.
;;
;; Run with GLAZE_NSIS_SMOKE=1 on an elevated Windows host with makensis on
;; PATH. The package CI job installs NSIS and sets that variable.

(require racket/file
         racket/path
         racket/port
         racket/string
         racket/system
         glaze/private/windows-installer-metadata)

(unless (getenv "GLAZE_NSIS_SMOKE")
  (displayln "NSIS smoke skipped (set GLAZE_NSIS_SMOKE=1 to run)")
  (exit 0))

(define makensis (find-executable-path "makensis" #f))
(unless makensis
  (error 'nsis-smoke "makensis is not on PATH"))

(define work (make-temporary-file "glaze-nsis-~a" 'directory))
(define dist (build-path work "dist"))
(make-directory* dist)
(define fake-exe (build-path dist "sampleapp.exe"))
(copy-file (find-executable-path "cmd.exe" #f) fake-exe)

(define nsi (build-path work "sampleapp.nsi"))
(call-with-output-file nsi
  (lambda (out)
    (display (windows-nsis "sampleapp" dist "0.0.1" "Turing Lambda"
                           "TuringLambda.Glaze.CISample")
             out))
  #:exists 'replace)

(define setup (build-path dist "sampleapp-setup.exe"))
(define program-files (or (getenv "ProgramW6432") (getenv "ProgramFiles")))
(unless program-files
  (error 'nsis-smoke "ProgramW6432/ProgramFiles is not set"))
(define install-dir (build-path program-files "sampleapp"))

(define (run! path . args)
  (unless (apply system* path args)
    (error 'nsis-smoke "command failed: ~a ~a" path args)))

(define (cleanup!)
  (when (file-exists? (build-path install-dir "Uninstall.exe"))
    (with-handlers ([exn:fail? void])
      (system* (build-path install-dir "Uninstall.exe") "/S")))
  (when (directory-exists? install-dir)
    (with-handlers ([exn:fail? void])
      (delete-directory/files install-dir)))
  (when (directory-exists? work)
    (delete-directory/files work)))

(dynamic-wind
 void
 (lambda ()
   (run! makensis nsi)
   (unless (file-exists? setup)
     (error 'nsis-smoke "makensis did not produce ~a" setup))
   (run! setup "/S")
   (unless (file-exists? (build-path install-dir "sampleapp.exe"))
     (error 'nsis-smoke "NSIS did not install sampleapp.exe"))
   (unless (file-exists? (build-path install-dir "Uninstall.exe"))
     (error 'nsis-smoke "NSIS did not write Uninstall.exe"))
   (run! (build-path install-dir "Uninstall.exe") "/S")
   (let loop ([tries 30])
     (cond
       [(directory-exists? install-dir)
        (when (zero? tries)
          (error 'nsis-smoke "uninstall left ~a" install-dir))
        (sleep 0.2)
        (loop (sub1 tries))]
       [else (void)])))
 (lambda () (cleanup!)))

(displayln "NSIS install/uninstall smoke passed")
