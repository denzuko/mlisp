;;;; src/nzb.lisp -- NZB XML generation
;;;;
;;;; NZB format: http://www.newzbin.com/DTD/2003/nzb
;;;; An NZB file is an XML document that maps segment Message-IDs to
;;;; the file and byte range they represent, allowing batch retrieval.
;;;; Generated purely with string formatting -- no xmls dependency
;;;; needed for output (only for parsing inbound, if needed).

(in-package #:com.dwightaspencer.nzb-indexer)

(defparameter *nzb-namespace*
  "http://www.newzbin.com/DTD/2003/nzb")

(defun build-nzb (idx title)
  "Generate NZB XML for the release named TITLE in IDX.
   Returns the NZB string, or nil if the release is not found."
  (let ((release (find-release idx title)))
    (unless release (return-from build-nzb nil))
    (let ((segments (sort (copy-list (release-segments release))
                          #'< :key #'segment-part)))
      (with-output-to-string (s)
        (format s "<?xml version=\"1.0\" encoding=\"utf-8\"?>~%")
        (format s "<!DOCTYPE nzb PUBLIC \"-//newzBin//DTD NZB 1.1//EN\"~%")
        (format s "  \"http://www.newzbin.com/DTD/nzb/nzb-1.1.dtd\">~%")
        (format s "<nzb xmlns=\"~A\">~%" *nzb-namespace*)
        (format s "  <head>~%")
        (format s "    <meta type=\"title\">~A</meta>~%" (xml-escape title))
        (format s "    <meta type=\"segments\">~A</meta>~%"
                (length segments))
        (format s "  </head>~%")
        (format s "  <file poster=\"distrib-nzb\" subject=\"~A\">~%"
                (xml-escape (format nil "[~A/~A] ~A"
                                    (segment-part   (car segments))
                                    (segment-total  (car segments))
                                    (segment-filename (car segments)))))
        (format s "    <groups>~%")
        (format s "      <group>mlisp.distrib</group>~%")
        (format s "    </groups>~%")
        (format s "    <segments>~%")
        (dolist (seg segments)
          (format s "      <segment bytes=\"~A\" number=\"~A\">~A</segment>~%"
                  (segment-size seg)
                  (segment-part seg)
                  ;; Strip angle brackets from Message-ID per NZB convention
                  (string-trim '(#\< #\>) (segment-message-id seg))))
        (format s "    </segments>~%")
        (format s "  </file>~%")
        (format s "</nzb>~%")))))

(defun xml-escape (str)
  "Escape XML special characters in STR."
  (with-output-to-string (s)
    (loop for c across str do
      (case c
        (#\& (write-string "&amp;"  s))
        (#\< (write-string "&lt;"   s))
        (#\> (write-string "&gt;"   s))
        (#\" (write-string "&quot;" s))
        (#\' (write-string "&apos;" s))
        (t   (write-char c s))))))
