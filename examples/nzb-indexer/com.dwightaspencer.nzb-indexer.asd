;;;; com.dwightaspencer.nzb-indexer.asd
;;;;
;;;; System hierarchy:
;;;;   com.dwightaspencer.nzb-indexer/core    -- release index, NZB builder
;;;;   com.dwightaspencer.nzb-indexer/service -- batch processor, command dispatch
;;;;   com.dwightaspencer.nzb-indexer/tests   -- FiveAM BDD suite
;;;;   com.dwightaspencer.nzb-indexer/doc     -- 40ants-doc pages

;;; ── Parent ───────────────────────────────────────────────────────────────
(defsystem "com.dwightaspencer.nzb-indexer"
  :description "NZB release indexer -- adds release-level abstraction over mlisp -distrib"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.1.0"
  :homepage "https://github.com/denzuko/mlisp"
  :depends-on ("com.dwightaspencer.nzb-indexer/service"))

;;; ── Core: release index + NZB builder ───────────────────────────────────
(defsystem "com.dwightaspencer.nzb-indexer/core"
  :description "Release index state + NZB XML generation"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.1.0"
  :depends-on ("cl-mime" "xmls")
  :components
  ((:file "src/package")
   (:file "src/index"   :depends-on ("src/package"))
   (:file "src/nzb"     :depends-on ("src/package"))))

;;; ── Service: batch processor + command dispatch ──────────────────────────
(defsystem "com.dwightaspencer.nzb-indexer/service"
  :description "Maildir batch processor and get-nzb command handler"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.1.0"
  :depends-on ("com.dwightaspencer.nzb-indexer/core")
  :components
  ((:file "src/routing")
   (:file "src/announce")
   (:file "src/main"    :depends-on ("src/routing" "src/announce")))
  :in-order-to ((test-op (test-op "com.dwightaspencer.nzb-indexer/tests"))))

;;; ── Tests ────────────────────────────────────────────────────────────────
(defsystem "com.dwightaspencer.nzb-indexer/tests"
  :description "FiveAM BDD spec suite"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.1.0"
  :depends-on ("com.dwightaspencer.nzb-indexer/service" "fiveam")
  :perform (test-op (op system)
    (declare (ignore op))
    (let ((cl-user::*nzb-indexer-test-no-exit* t)
          (root (asdf:system-source-directory system)))
      (declare (special cl-user::*nzb-indexer-test-no-exit*))
      (load (merge-pathnames "test/fiveam/test-nzb-indexer.lisp" root)))))

;;; ── Documentation ────────────────────────────────────────────────────────
(defsystem "com.dwightaspencer.nzb-indexer/doc"
  :description "40ants-doc pages for nzb-indexer"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.1.0"
  :depends-on ("com.dwightaspencer.nzb-indexer/service" "40ants-doc")
  :components
  ((:file "doc/index")))
