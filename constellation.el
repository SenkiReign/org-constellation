;;; constellation.el --- Browse linked Org notes as a list, a star chart and a reader -*- lexical-binding: t; -*-

;; Author: Senki R.  
;; URL: https://github.com/you/constellation
;; Version: 1.0.4
;; Package-Requires: ((emacs "27.1"))
;;; Commentary:
;;
;; Browse a folder of Org notes (or one big Org file):
;;
;;   LEFT   list of notes (filter, sort by recent / most linked / A-Z)
;;   RIGHT  top:    the selected note in the middle of its connections
;;                  (left = links to it, right = links from it,
;;                   top/bottom = mentioned together in your journal)
;;          bottom: the note itself, with "linked from" and journal mentions
;;
;; Setup:
;;
;;   (setq constellation-sources '("~/org"))   ; files and/or directories
;;   M-x constellation
;;
;; A note is every .org file when you point it at several files, or every
;; top-level heading when you point it at one file (`constellation-node-kind').
;; Files named like 2026-10-19.org or 20261019.org are a journal: they feed
;; dates and "mentioned together".  So do headings that start with a date.
;;
;; Links understood: [[Title]] [[*Heading]] [[file:x.org]] [[id:UUID]] and
;; external links.  A [[Title]] without a note shows as a dim "ghost" note.
;;
;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'org)

(defvar org-todo-keywords)
(defvar org-directory)

;;;; Options --------------------------------------------------------------

(defgroup constellation nil "Linked Org notes browser." :group 'org)

(defcustom constellation-sources nil
  "Org files and/or directories to read.  Nil means `org-directory'."
  :type '(repeat file) :group 'constellation)

(defcustom constellation-node-kind 'auto
  "What a note is: `file', `heading', or `auto'.
With `auto', one source file means heading notes, several mean file notes."
  :type '(choice (const auto) (const file) (const heading)) :group 'constellation)

(defcustom constellation-heading-level 1
  "Heading level that counts as a note in `heading' mode."
  :type 'integer :group 'constellation)

(defcustom constellation-journal-file-regexp
  "\\`[0-9]\\{4\\}-?[0-9]\\{2\\}-?[0-9]\\{2\\}\\(?:[^0-9T]\\|\\'\\)"
  "File names (without directory) matching this are journal files, not notes."
  :type 'regexp :group 'constellation)

(defcustom constellation-exclude-regexp "\\(?:/\\.\\|/archive/\\|~\\'\\|/#\\)"
  "Files whose absolute name matches this are ignored."
  :type 'regexp :group 'constellation)

(defcustom constellation-height-margin 1
  "Lines kept free at the bottom of the window.  Use 2 if the key bar is cut off."
  :type 'integer :group 'constellation)

(defvar constellation-dims-override nil "Testing: (WIDTH . TOTAL-HEIGHT) instead of the window size.")

;;;; Faces ----------------------------------------------------------------

(defmacro constellation--faces (&rest specs)
  "Define faces from (NAME DARK-PROPS LIGHT-PROPS) specs."
  `(progn
     ,@(mapcar (lambda (s)
                 `(defface ,(car s) '((((background dark)) ,@(nth 1 s)) (t ,@(nth 2 s)))
                    ,(format "Constellation face %s." (car s))
                    :group 'constellation))
               specs)))

(constellation--faces
 (constellation-star      (:foreground "#17301f") (:foreground "#c5d9c9"))
 (constellation-edge      (:foreground "#1f5f37") (:foreground "#7fb694"))
 (constellation-edge-hot  (:foreground "#9dffb8" :weight bold) (:foreground "#0f7a3a" :weight bold))
 (constellation-co-hot    (:foreground "#5fe0f0" :weight bold) (:foreground "#0a7f8f" :weight bold))
 (constellation-node      (:foreground "#58d68d") (:foreground "#2a8a55"))
 (constellation-warm      (:foreground "#a6ffc2" :weight bold) (:foreground "#0f7a3a" :weight bold))
 (constellation-hot       (:foreground "#ffb000" :weight bold) (:foreground "#b36b00" :weight bold))
 (constellation-cold      (:foreground "#3a7a50") (:foreground "#7aa98a"))
 (constellation-nbr       (:foreground "#e4fff0" :weight bold) (:foreground "#0b3d1e" :weight bold))
 (constellation-sel       (:foreground "#06130a" :background "#ffd75f" :weight bold) (:foreground "#ffffff" :background "#b36b00" :weight bold))
 (constellation-cur       (:foreground "#06130a" :background "#5fe0f0" :weight bold) (:foreground "#ffffff" :background "#0a7f8f" :weight bold))
 (constellation-pick      (:foreground "#06130a" :background "#ff9f43" :weight bold) (:foreground "#ffffff" :background "#c2571a" :weight bold))
 (constellation-flank     (:foreground "#ffd75f" :weight bold) (:foreground "#b36b00" :weight bold))
 (constellation-packet    (:foreground "#ffd75f" :weight bold) (:foreground "#b36b00" :weight bold))
 (constellation-packet-co (:foreground "#5fe0f0" :weight bold) (:foreground "#0a7f8f" :weight bold))
 (constellation-frame     (:foreground "#1f5f37") (:foreground "#8fbf9f"))
 (constellation-hud       (:foreground "#79c28f") (:foreground "#4a7a5a"))
 (constellation-title     (:foreground "#ffb000" :weight bold) (:foreground "#b36b00" :weight bold))
 (constellation-key       (:foreground "#ffd75f") (:foreground "#8a5a00"))
 (constellation-dim       (:foreground "#3a7a50") (:foreground "#6f9a7f"))
 ;; reader
 (constellation-text      (:foreground "#b7e4c4") (:foreground "#24402e"))
 (constellation-h1        (:foreground "#ffb000" :weight bold) (:foreground "#b36b00" :weight bold))
 (constellation-h2        (:foreground "#ffd75f" :weight bold) (:foreground "#8a6a00" :weight bold))
 (constellation-h3        (:foreground "#a6ffc2" :weight bold) (:foreground "#1f7a45" :weight bold))
 (constellation-h4        (:foreground "#79c28f" :weight bold) (:foreground "#4a7a5a" :weight bold))
 (constellation-link      (:foreground "#5fe0f0" :underline t) (:foreground "#0a6f8f" :underline t))
 (constellation-ghost-link (:foreground "#b58a3c" :underline t) (:foreground "#9a6a1c" :underline t))
 (constellation-ext-link  (:foreground "#6f9fb0" :underline t) (:foreground "#3f6f8f" :underline t))
 (constellation-bold      (:foreground "#f2fff6" :weight bold) (:foreground "#07210f" :weight bold))
 (constellation-italic    (:foreground "#d6f5e0" :slant italic) (:foreground "#24402e" :slant italic))
 (constellation-uline     (:underline t) (:underline t))
 (constellation-code      (:foreground "#e0b36a") (:foreground "#9a5a00"))
 (constellation-strike    (:strike-through t) (:strike-through t))
 (constellation-todo      (:foreground "#ff6b5c" :weight bold) (:foreground "#c0392b" :weight bold))
 (constellation-done      (:foreground "#3a7a50" :weight bold) (:foreground "#6f9a7f" :weight bold))
 (constellation-table     (:foreground "#79c28f") (:foreground "#4a7a5a"))
 (constellation-src       (:foreground "#9ad0a6" :background "#0b160e") (:foreground "#2a5a3a" :background "#e4efe6"))
 (constellation-stamp     (:foreground "#8aa0d0") (:foreground "#4a5f9a"))
 (constellation-bullet    (:foreground "#ffb000") (:foreground "#b36b00")))

;;;; Data -----------------------------------------------------------------

(cl-defstruct (constellation--n (:constructor constellation--n-new (title kind file line)))
  title lc i kind file line id (exists t) date plevel
  (mentions 0) last age text outs ins nbrs inc snips backs
  gx gy shown lab (deg 0))

(cl-defstruct constellation--g nodes edges sig clusters reg)

;; A jumpable thing in the note pane.  KIND: link, back, journal or url.
;; NODE: note index (link/back).  LOC: (FILE . LINE) in the org files.
;; URL: external link target.  SEGS: list of (ROW START END) in the note
;; lines (a wrapped link has several).  OCC: id of the link occurrence.
(cl-defstruct (constellation--it (:constructor constellation--it-new (kind node loc url segs occ)))
  kind node loc url segs occ)

(defvar constellation--occ 0 "Counter giving every rendered link occurrence a unique id.")
(cl-defstruct constellation--reg (titles (make-hash-table :test 'equal))
  (files (make-hash-table :test 'equal)) (ids (make-hash-table :test 'equal)))

(defconst constellation--link-re "\\[\\[\\([^]\n]+?\\)\\]\\(?:\\[\\([^]\n]*\\)\\]\\)?\\]")
(defconst constellation--scheme-re "\\`[a-zA-Z][a-zA-Z0-9+.-]+:")
(defconst constellation--date-re "\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)")

(defun constellation--links (line)
  "Raw link targets found in LINE."
  (let ((pos 0) acc)
    (while (string-match constellation--link-re line pos)
      (let ((l (string-trim (match-string 1 line))))
        (setq pos (match-end 0))
        (unless (string-empty-p l) (push l acc))))
    (nreverse acc)))

(defun constellation--file-date (base)
  "YYYY-MM-DD from a file name like 2026-10-19.org or 20261019.org, else nil."
  (when (string-match "\\`\\([0-9]\\{4\\}\\)-?\\([0-9]\\{2\\}\\)-?\\([0-9]\\{2\\}\\)" base)
    (format "%s-%s-%s" (match-string 1 base) (match-string 2 base) (match-string 3 base))))

(defun constellation--date-in (s) (and s (string-match constellation--date-re s) (match-string 1 s)))

(defun constellation--todo-words ()
  "Return (ALL . DONE) keyword lists from `org-todo-keywords'."
  (let (all done)
    (dolist (seq (if (boundp 'org-todo-keywords) org-todo-keywords '((sequence "TODO" "DONE"))))
      (when (consp seq)
        (let ((after nil) (kws (cl-remove-if-not #'stringp (cdr seq))))
          (dolist (k kws)
            (if (equal k "|") (setq after t)
              (let ((w (replace-regexp-in-string "(.*)" "" k)))
                (push w all) (when after (push w done)))))
          (unless (member "|" kws) (when all (push (car (last kws)) done))))))
    (cons (delete "" (delete-dups all)) (delete-dups (mapcar (lambda (k) (replace-regexp-in-string "(.*)" "" (or k ""))) done)))))

(defun constellation--split-heading (raw)
  "Return (KEYWORD . CLEAN-TITLE) for the heading text RAW."
  (let ((s raw) kw)
    (when (string-match (concat "\\`" (regexp-opt (car (constellation--todo-words)) t) "\\(?:[ \t]+\\|\\'\\)") s)
      (setq kw (match-string 1 s) s (substring s (match-end 0))))
    (setq s (replace-regexp-in-string "\\`\\[#[A-Z0-9]\\][ \t]*" "" s))
    (setq s (replace-regexp-in-string "[ \t]+:[[:alnum:]_@#%:]+:[ \t]*\\'" "" s))
    (setq s (replace-regexp-in-string "[ \t]*\\[[0-9]*\\(?:/[0-9]*\\|%\\)\\]" "" s))
    (setq s (replace-regexp-in-string constellation--link-re (lambda (m) (or (match-string 2 m) (match-string 1 m))) s t t))
    (cons kw (string-trim s))))

(defun constellation--clean-title (raw) (cdr (constellation--split-heading raw)))

(defun constellation--ew (e) (+ (* 2 (+ (nth 2 e) (nth 3 e))) (nth 4 e)))

;;;; Reading the files ----------------------------------------------------

(defun constellation--files ()
  (let* ((src (or constellation-sources (list org-directory)))
         files)
    (dolist (s (if (listp src) src (list src)))
      (let ((f (expand-file-name s)))
        (cond ((file-directory-p f)
               (dolist (x (directory-files-recursively
                           f "\\.org\\'" nil
                           (lambda (d) (not (string-prefix-p "." (file-name-nondirectory d))))))
                 (unless (string-match-p constellation-exclude-regexp x) (push x files))))
              ((file-readable-p f) (push f files)))))
    (delete-dups (nreverse files))))

(defun constellation--read (file)
  (if-let ((b (find-buffer-visiting file)))
      (with-current-buffer b
        (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max))))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8)) (insert-file-contents file))
      (buffer-string))))

(defun constellation--mtime (file)
  (ignore-errors
    (format-time-string "%Y-%m-%d" (file-attribute-modification-time (file-attributes file)))))

(defun constellation--file-title (lines base)
  (or (cl-loop for l in lines repeat 40
               when (string-match "\\`#\\+title:[ \t]*\\(.+\\)" l)
               return (constellation--clean-title (match-string 1 l)))
      (file-name-sans-extension base)))

;;;; Link resolution ------------------------------------------------------

(defun constellation--by-title (reg title pref-file)
  (let ((l (gethash (downcase (string-trim title)) (constellation--reg-titles reg))))
    (or (and pref-file (cl-find pref-file l :key #'constellation--n-file :test #'equal))
        (car (last l)))))

(defun constellation--resolve (reg target from-file create)
  "Find the note TARGET points to (a link target string).
CREATE is a function that makes ghost notes, or nil."
  (let* ((tg (string-trim target))
         (fl (cond ((string-match "\\`file:\\(.*?\\)\\(?:::\\(.*\\)\\)?\\'" tg)
                    (cons (match-string 1 tg) (match-string 2 tg)))
                   ((and (not (string-match-p constellation--scheme-re tg))
                         (string-match "\\`\\(.*?\\.org\\)\\(?:::\\(.*\\)\\)?\\'" tg))
                    (cons (match-string 1 tg) (match-string 2 tg))))))
    (cond
     ((string-match "\\`id:\\(.+\\)\\'" tg) (gethash (match-string 1 tg) (constellation--reg-ids reg)))
     (fl (let* ((abs (expand-file-name (car fl) (and from-file (file-name-directory from-file))))
                (fnode (gethash abs (constellation--reg-files reg))))
           (or fnode
               (and (cdr fl) (constellation--by-title reg (string-remove-prefix "*" (cdr fl)) abs)))))
     ((string-prefix-p "*" tg) (constellation--by-title reg (substring tg 1) from-file))
     ((string-prefix-p "#" tg) nil)
     ((string-match-p constellation--scheme-re tg) nil)
     (t (or (constellation--by-title reg tg from-file)
            (and create (funcall create tg)))))))

;;;; Parsing --------------------------------------------------------------

(defun constellation--parse ()
  "Read all sources into a `constellation--g'."
  (let* ((files (constellation--files))
         (kind0 (pcase constellation-node-kind ('auto (if (= (length files) 1) 'heading 'file)) (k k)))
         (reg (make-constellation--reg))
         nodes plinks ctxs)
    (cl-labels ((add-node (nd) (push nd nodes) (push nd (gethash (constellation--n-lc nd) (constellation--reg-titles reg))) nd))
      (dolist (file files)
        (let* ((lines (split-string (constellation--read file) "\r?\n"))
               (base (file-name-nondirectory file))
               (journalp (string-match-p constellation-journal-file-regexp base))
               (kind kind0)
               (plevel constellation-heading-level)
               (fdate (and journalp (constellation--file-date base)))
               (dates (make-vector 40 nil))
               (ln 0) cur ctx)
          (cl-labels
              ((new-node (title k line lvl date)
                 (let ((nd (constellation--n-new title k file line)))
                   (setf (constellation--n-lc nd) (downcase title) (constellation--n-plevel nd) lvl (constellation--n-date nd) date)
                   (add-node nd)))
               (flush-ctx () (when (and ctx (aref ctx 2)) (push ctx ctxs)) (setq ctx nil))
               (start-ctx (date head)
                 (flush-ctx)
                 (setq ctx (vector date head nil file
                                   (or (string-empty-p head)
                                       (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\(?: [[:alpha:]]+\\)?\\'" head)))))
               (eff-date (lvl) (or (cl-loop for l from lvl downto 1 thereis (aref dates l)) fdate))
               (take (line)
                 (let ((ls (constellation--links line)))
                   (when ls
                     (cond (cur (dolist (tt ls) (push (list cur tt line file ln) plinks)))
                           (ctx (when (aref ctx 4)
                                  (aset ctx 1 (constellation--clean-title line)) (aset ctx 4 nil))
                                (dolist (tt ls) (push (cons tt ln) (aref ctx 2)))))))))
            (when (and (eq kind 'file) (not journalp))
              (setq cur (new-node (constellation--file-title lines base) 'file 1 0 (constellation--mtime file))))
            (when journalp (start-ctx fdate (or fdate (file-name-sans-extension base))))
            (dolist (line lines)
              (cl-incf ln)
              (if (string-match "\\`\\(\\*+\\)[ \t]+\\(.*?\\)[ \t]*\\'" line)
                  (let* ((lvl (min 39 (length (match-string 1 line)))) (raw (match-string 2 line))
                         (title (constellation--clean-title raw)) (d (constellation--date-in raw)))
                    (when (and cur (> (constellation--n-plevel cur) 0) (<= lvl (constellation--n-plevel cur))) (setq cur nil))
                    (aset dates lvl d)
                    (cl-loop for l from (1+ lvl) below 40 do (aset dates l nil))
                    (cond
                     ((and (eq kind 'heading) (not journalp) (= lvl plevel)
                          (not (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}" title)))
                      (flush-ctx)
                      (setq cur (new-node title 'heading ln lvl d)))
                     (cur (push line (constellation--n-text cur)) (take line))
                     (t (start-ctx (eff-date lvl) title) (take line))))
                (cond
                 (cur (push line (constellation--n-text cur))
                      (when (string-match "\\`[ \t]*:ID:[ \t]+\\([^ \t]+\\)" line)
                        (let ((id (match-string 1 line)))
                          (unless (constellation--n-id cur) (setf (constellation--n-id cur) id))
                          (puthash id cur (constellation--reg-ids reg))))
                      (take line))
                 (ctx (take line)))))
            (flush-ctx))))
      ;; file nodes are reachable by path
      (dolist (nd nodes)
        (when (eq (constellation--n-kind nd) 'file) (puthash (constellation--n-file nd) nd (constellation--reg-files reg))))
      ;; ---- resolve links
      (let (rl rc)
        (cl-flet ((ghost (title)
                    (let ((nd (constellation--n-new title 'ghost nil nil)))
                      (setf (constellation--n-lc nd) (downcase title) (constellation--n-exists nd) nil (constellation--n-plevel nd) 0)
                      (add-node nd))))
          (let ((mk #'ghost))
            (dolist (p (nreverse plinks))
              (let ((tg (constellation--resolve reg (nth 1 p) (nth 3 p) mk)))
                (when (and tg (not (eq tg (car p)))) (push (list (car p) tg (nth 2 p) (nth 3 p) (nth 4 p)) rl))))
            (dolist (c (nreverse ctxs))
              (let (tgs lns)
                (dolist (tt (nreverse (aref c 2)))
                  (let ((tg (constellation--resolve reg (car tt) (aref c 3) mk)))
                    (when tg (cl-pushnew tg tgs :test #'eq) (unless (assq tg lns) (push (cons tg (cdr tt)) lns)))))
                (when tgs (push (list (aref c 0) (aref c 1) (nreverse tgs) (aref c 3) lns) rc))))))
        (setq rl (nreverse rl) rc (nreverse rc))
        ;; ---- index nodes
        (let* ((vec (vconcat (sort nodes (lambda (a b)
                                           (or (string< (constellation--n-lc a) (constellation--n-lc b))
                                               (and (string= (constellation--n-lc a) (constellation--n-lc b))
                                                    (< (or (constellation--n-line a) 0) (or (constellation--n-line b) 0))))))))
               (n (length vec)) (etab (make-hash-table :test 'equal)) (seenp (make-hash-table :test 'equal))
               edges)
          (dotimes (i n) (setf (constellation--n-i (aref vec i)) i (constellation--n-text (aref vec i)) (nreverse (constellation--n-text (aref vec i)))))
          (cl-flet ((ent (a b)
                      (let ((key (cons (min a b) (max a b))))
                        (or (gethash key etab) (puthash key (vector 0 0 0) etab)))))
            (dolist (r rl)
              (let* ((a (constellation--n-i (nth 0 r))) (b (constellation--n-i (nth 1 r))) (v (ent a b)))
                (if (< a b) (cl-incf (aref v 0)) (cl-incf (aref v 1)))
                (cl-pushnew b (constellation--n-outs (nth 0 r)))
                (cl-pushnew a (constellation--n-ins (nth 1 r)))
                (unless (gethash (cons a b) seenp)
                  (puthash (cons a b) t seenp)
                  (push (list a (replace-regexp-in-string
                                 "\\`[-+*0-9.) \t]+" "" (constellation--clean-title (string-trim (nth 2 r))))
                        (nth 3 r) (nth 4 r))
                        (constellation--n-backs (nth 1 r))))))
            (dolist (c rc)
              (let ((date (nth 0 c)) (head (nth 1 c)) (tgs (nth 2 c)) (cfile (nth 3 c)) (lns (nth 4 c)))
                (dolist (tg tgs)
                  (cl-incf (constellation--n-mentions tg))
                  (when (and date (or (null (constellation--n-last tg)) (string> date (constellation--n-last tg))))
                    (setf (constellation--n-last tg) date))
                  (push (list (or date "") head cfile (cdr (assq tg lns))) (constellation--n-snips tg)))
                (let ((cap (seq-take tgs 12)))
                  (while cap
                    (dolist (b (cdr cap))
                      (cl-incf (aref (ent (constellation--n-i (car cap)) (constellation--n-i b)) 2)))
                    (setq cap (cdr cap)))))))
          (maphash (lambda (k v) (push (list (car k) (cdr k) (aref v 0) (aref v 1) (aref v 2)) edges)) etab)
          (setq edges (sort edges (lambda (x y) (or (< (car x) (car y))
                                                    (and (= (car x) (car y)) (< (cadr x) (cadr y)))))))
          (dolist (e edges)
            (let* ((i (nth 0 e)) (j (nth 1 e)) (w (constellation--ew e)))
              (push (cons j w) (constellation--n-nbrs (aref vec i)))
              (push (cons i w) (constellation--n-nbrs (aref vec j)))
              (push e (constellation--n-inc (aref vec i)))
              (push e (constellation--n-inc (aref vec j)))))
          (cl-loop for nd across vec
                   do (setf (constellation--n-nbrs nd)
                            (sort (constellation--n-nbrs nd)
                                  (lambda (a b) (or (> (cdr a) (cdr b))
                                                    (and (= (cdr a) (cdr b)) (< (car a) (car b)))))))
                   do (when (and (constellation--n-date nd) (or (null (constellation--n-last nd)) (string> (constellation--n-date nd) (constellation--n-last nd))))
                        (setf (constellation--n-last nd) (constellation--n-date nd)))
                   do (setf (constellation--n-deg nd) (length (constellation--n-nbrs nd))
                            (constellation--n-age nd) (constellation--age (constellation--n-last nd))
                            (constellation--n-backs nd) (nreverse (constellation--n-backs nd))
                            (constellation--n-snips nd) (seq-take (sort (constellation--n-snips nd)
                                                             (lambda (a b) (string> (car a) (car b))))
                                                       10)))
          (let ((seen (make-vector n nil)) (clusters 0))
            (dotimes (i n)
              (when (and (not (aref seen i)) (> (constellation--n-deg (aref vec i)) 0))
                (cl-incf clusters)
                (let ((stack (list i)))
                  (aset seen i t)
                  (while stack
                    (dolist (nb (constellation--n-nbrs (aref vec (pop stack))))
                      (unless (aref seen (car nb)) (aset seen (car nb) t) (push (car nb) stack)))))))
            (make-constellation--g :nodes vec :edges edges :clusters clusters :reg reg
                        :sig (sxhash-equal (list (mapcar #'constellation--n-title vec) edges)))))))))

(defun constellation--age (last)
  (when (and last (string-match "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}" last))
    (ignore-errors
      (/ (- (float-time) (float-time (date-to-time (concat (match-string 0 last) " 00:00:00")))) 86400.0))))

;;;; State ----------------------------------------------------------------

(defvar-local constellation--graph nil)
(defvar-local constellation--sel 0)
(defvar-local constellation--cur nil "Highlighted neighbour on the ring, or nil.")
(defvar-local constellation--ring1 nil)
(defvar-local constellation--groups '(0 0 0))
(defvar-local constellation--sort 'recent)
(defvar-local constellation--filter "")
(defvar-local constellation--layout 'split)
(defvar-local constellation--list nil)
(defvar-local constellation--listpos nil)
(defvar-local constellation--list-key nil)
(defvar-local constellation--top 0)
(defvar-local constellation--hist nil)
(defvar-local constellation--nscroll 0)
(defvar-local constellation--note-cache nil)
(defvar-local constellation--origin 1)
(defvar-local constellation--cellbase 0)
(defvar-local constellation--stride 80)
(defvar-local constellation--dims-last nil)
(defvar-local constellation--packets nil)
(defvar-local constellation--timer nil)
(defvar-local constellation--wconf nil)
(defvar-local constellation--items [] "Jumpable things in the note pane (vector of `constellation--it').")
(defvar-local constellation--item nil "Index of the picked item in `constellation--items', or nil.")

(defun constellation--dims ()
  "Return (W LIST-WIDTH PANE-WIDTH ROWS GRAPH-ROWS NOTE-ROWS)."
  (let* ((ov constellation-dims-override)
         (win (or (get-buffer-window (current-buffer)) (selected-window)))
         (w (if ov (car ov) (max 60 (1- (window-body-width win)))))
         (th (if ov (cdr ov) (- (window-body-height win) constellation-height-margin)))
         (lw (if (< w 100) 24 30))
         (rows (max 10 (- th 5)))
         (lay constellation--layout)
         (lay (if (and (eq lay 'split) (< rows 17)) 'note lay))
         (gh (pcase lay ('graph rows) ('note 0)
               (_ (max 9 (min (- rows 8) (round (* rows 0.44)))))))
         (nh (- rows gh)))
    (list w lw (- w lw 1) rows gh nh)))

(defun constellation--cell (x y) (+ constellation--origin (* y constellation--stride) constellation--cellbase x))

;;;; List -----------------------------------------------------------------

(defun constellation--ensure-list ()
  (let* ((g constellation--graph)
         (key (list constellation--sort constellation--filter (constellation--g-sig g) (length (constellation--g-nodes g)))))
    (unless (equal key constellation--list-key)
      (let* ((nodes (constellation--g-nodes g)) (n (length nodes))
             (words (split-string (downcase constellation--filter) " " t)) idxs)
        (dotimes (i n)
          (when (cl-every (lambda (w) (string-match-p (regexp-quote w) (constellation--n-lc (aref nodes i)))) words)
            (push i idxs)))
        (setq idxs
              (sort idxs
                    (pcase constellation--sort
                      ('links (lambda (a b) (let ((da (constellation--n-deg (aref nodes a))) (db (constellation--n-deg (aref nodes b))))
                                              (or (> da db) (and (= da db) (< a b))))))
                      ('az (lambda (a b) (< a b)))
                      (_ (lambda (a b) (let ((la (or (constellation--n-last (aref nodes a)) ""))
                                             (lb (or (constellation--n-last (aref nodes b)) "")))
                                         (or (string> la lb) (and (string= la lb) (< a b)))))))))
        (setq constellation--list (vconcat idxs) constellation--listpos (make-vector n -1) constellation--list-key key)
        (dotimes (p (length constellation--list)) (aset constellation--listpos (aref constellation--list p) p))))))

(defun constellation--heat-face (nd)
  (let ((a (constellation--n-age nd)))
    (cond ((null a) 'constellation-cold) ((<= a 3) 'constellation-hot) ((<= a 14) 'constellation-warm)
          ((<= a 60) 'constellation-node) (t 'constellation-cold))))

(defun constellation--fit (s w) (truncate-string-to-width s (max 0 w) nil ?\s "~"))
(defun constellation--trunc (s n) (if (> (length s) n) (concat (substring s 0 (max 0 (1- n))) "~") s))

(defun constellation--list-row (nd i lw face selp)
  (let* ((deg (constellation--n-deg nd))
         (glyph (cond ((not (constellation--n-exists nd)) "?") ((= deg 0) "·") ((<= deg 2) "o") ((<= deg 5) "O") (t "@")))
         (txt (format "%s %s %s %s" (if selp ">" " ") glyph (constellation--fit (constellation--n-title nd) (- lw 8))
                      (if (> deg 0) (format "%3d" deg) "   "))))
    (propertize txt 'face face 'constellation-node i)))

;;;; Orbit projection -----------------------------------------------------

(defun constellation--reset-screen (nodes)
  (cl-loop for nd across nodes
           do (setf (constellation--n-gx nd) nil (constellation--n-gy nd) nil (constellation--n-shown nd) nil (constellation--n-lab nd) nil)))

(defun constellation--rel (e sel)
  (let* ((fw (nth 2 e)) (bw (nth 3 e))
         (fwd (if (= (nth 0 e) sel) fw bw)) (back (if (= (nth 0 e) sel) bw fw)))
    (cond ((> fwd 0) 'out) ((> back 0) 'in) (t 'co))))

(defun constellation--edge-between (nodes a b)
  (cl-find-if (lambda (e) (or (= (nth 0 e) b) (= (nth 1 e) b))) (constellation--n-inc (aref nodes a))))

(defun constellation--project-orbit (g sel W H)
  "Centre SEL, ring its neighbours.  Returns (SHOWN . BACKGROUND-EDGES)."
  (let* ((nodes (constellation--g-nodes g)) (s (aref nodes sel))
         (hw (/ W 2.0)) (hh (/ H 2.0))
         (rx (max 12.0 (- hw 18.0))) (ry (max 3.0 (- hh 2.5)))
         (cap1 (max 6 (min 30 (- H 4))))
         (top (seq-take (constellation--n-nbrs s) cap1))
         (ins nil) (outs nil) (cos nil) (used (make-hash-table)) shown bg)
    (dolist (nb top)
      (let ((rel (constellation--rel (constellation--edge-between nodes sel (car nb)) sel)))
        (push (car nb) (pcase rel ('in ins) ('out outs) (_ cos)))))
    (cl-flet ((by-title (l) (sort l (lambda (a b) (< a b)))))
      (setq ins (by-title ins) outs (by-title outs) cos (by-title cos)))
    (let* ((c1 (ceiling (length cos) 2.0))
           (cos-top (seq-take cos c1)) (cos-bot (reverse (nthcdr c1 cos)))
           (ring (append cos-top outs cos-bot ins))
           (m (length ring)) (a (length outs))
           (step (/ (* 2 float-pi) (max 1 m)))
           (r2 nil) (k 0) (total2 0) (cap2 (max 6 (min 40 (* 2 (- H 4))))))
      (setq constellation--ring1 ring constellation--groups (list (length ins) (length outs) (length cos)))
      (puthash sel t used)
      (dolist (i ring) (puthash i t used))
      (cl-flet ((place (i c r)
                  (let ((nd (aref nodes i)))
                    (setf (constellation--n-gx nd) (round c) (constellation--n-gy nd) (round r) (constellation--n-shown nd) t)
                    (push i shown))))
        (place sel hw hh)
        (dolist (i ring)
          (let* ((th (* (- (+ k 0.5) (+ c1 (/ a 2.0))) step))
                 (f1 (if (> m 14) (if (cl-evenp k) 0.5 0.74) 0.62)))
            (place i (+ hw (* rx f1 (cos th))) (+ hh (* ry f1 (sin th))))
            (push (cons i th) r2)
            (cl-incf k)))
        (setq r2 (nreverse r2))
        (dolist (p r2)
          (let ((per (if (> m 10) 1 2)) (got 0) (th0 (cdr p)))
            (dolist (nb (constellation--n-nbrs (aref nodes (car p))))
              (when (and (< got per) (< total2 cap2) (not (gethash (car nb) used)))
                (puthash (car nb) t used)
                (let ((th (+ th0 (* step 0.28 (if (= per 1) 0 (if (= got 0) -1 1))))))
                  (place (car nb) (+ hw (* rx (if (= got 0) 1.0 0.9) (cos th)))
                         (+ hh (* ry (if (= got 0) 1.0 0.9) (sin th)))))
                (push (constellation--edge-between nodes (car p) (car nb)) bg)
                (cl-incf got) (cl-incf total2)))))
        (dolist (i ring)
          (dolist (e (constellation--n-inc (aref nodes i)))
            (let ((o (if (= (nth 0 e) i) (nth 1 e) (nth 0 e))))
              (when (and (< i o) (/= o sel) (memq o ring) (> (+ (nth 2 e) (nth 3 e)) 0))
                (push e bg)))))))
    (cons (nreverse shown) (delq nil bg))))

;;;; Graph drawing helpers ------------------------------------------------

(defconst constellation--bits [#x01 #x08 #x02 #x10 #x04 #x20 #x40 #x80])

(defun constellation--line (x0 y0 x1 y1)
  (let* ((dx (abs (- x1 x0))) (dy (- (abs (- y1 y0))))
         (sx (if (< x0 x1) 1 -1)) (sy (if (< y0 y1) 1 -1))
         (err (+ dx dy)) (x x0) (y y0) pts done)
    (while (not done)
      (push (cons x y) pts)
      (if (and (= x x1) (= y y1)) (setq done t)
        (let ((e2 (* 2 err)))
          (when (>= e2 dy) (cl-incf err dy) (cl-incf x sx))
          (when (<= e2 dx) (cl-incf err dx) (cl-incf y sy)))))
    (nreverse pts)))

(defun constellation--clear-packets ()
  (dolist (p constellation--packets) (delete-overlay (car p)))
  (setq constellation--packets nil))

(defun constellation--spawn (nodes sel-edges sel occ WG H)
  (constellation--clear-packets)
  (let ((count 0) (s (aref nodes sel)))
    (dolist (e sel-edges)
      (let* ((i (nth 0 e)) (j (nth 1 e)) (oi (if (= i sel) j i)) (o (aref nodes oi)))
        (when (and (< count 14) (constellation--n-shown o))
          (let* ((linkp (> (+ (nth 2 e) (nth 3 e)) 0))
                 (incoming (eq (constellation--rel e sel) 'in))
                 (path (cl-remove-if
                        (lambda (c) (or (< (car c) 0) (>= (car c) WG) (< (cdr c) 0) (>= (cdr c) H)
                                        (gethash (+ (* (cdr c) 4096) (car c)) occ)))
                        (constellation--line (constellation--n-gx s) (constellation--n-gy s) (constellation--n-gx o) (constellation--n-gy o))))
                 (path (vconcat (if incoming (reverse path) path)))
                 (len (length path)))
            (when (>= len 2)
              (cl-incf count)
              (dolist (ph (if (> len 10) (list (random len) nil) (list (random len))))
                (let* ((ph (or ph (mod (+ (nth 2 (car constellation--packets)) (/ len 2)) len)))
                       (c (aref path ph)) (q (constellation--cell (car c) (cdr c)))
                       (ov (make-overlay q (1+ q))))
                  (overlay-put ov 'priority 100)
                  (overlay-put ov 'display (propertize (if linkp "*" "+") 'face
                                                       (if linkp 'constellation-packet 'constellation-packet-co)))
                  (push (list ov path ph) constellation--packets))))))))))

;;;; The reader: org text -> styled, wrapped lines ------------------------

(defconst constellation--emph-re
  "\\(?:\\`\\|[ \t(\\[{'\"-]\\)\\(\\([*/_=~+]\\)\\([^ \t\n*/_=~+]\\(?:[^\n]*?[^ \t\n]\\)?\\)\\2\\)\\(?:[ \t.,;:!?'\")}\\\\-]\\|\\'\\)")

(defun constellation--wrap (s width hang)
  "Break the propertized string S into lines of at most WIDTH chars."
  (let* ((hang (min hang (/ width 2))) (hs (make-string hang ?\s)) out)
    (while (> (length s) width)
      (let ((brk (cl-loop for i from width downto (1+ hang) when (eq (aref s i) ?\s) return i)))
        (if brk
            (progn (push (string-trim-right (substring s 0 brk)) out)
                   (setq s (concat hs (string-trim-left (substring s brk)))))
          (push (substring s 0 width) out)
          (setq s (concat hs (substring s width))))))
    (push s out)
    (nreverse out)))

(defun constellation--style (txt g from-file)
  "Turn one logical org text line TXT into a propertized string (links, emphasis)."
  (let ((s txt) (pos 0) pieces)
    (while (string-match constellation--link-re s pos)
      (let* ((mb (match-beginning 0)) (me (match-end 0)) (target (match-string 1 s))
             (desc (let ((d (match-string 2 s)))
                     (if (and d (not (string-empty-p d))) d
                       (replace-regexp-in-string "\\`\\(?:file:\\|\\*\\)" "" target))))
             (node (constellation--resolve (constellation--g-reg g) target from-file nil)))
        (push (substring s pos mb) pieces)
        (push (propertize desc 'face (cond ((and node (constellation--n-exists node)) 'constellation-link)
                                           (node 'constellation-ghost-link)
                                           ((string-match-p constellation--scheme-re (string-trim target)) 'constellation-ext-link)
                                           (t 'constellation-ghost-link))
                          'constellation-node (and node (constellation--n-i node))
                          'cn-occ (cl-incf constellation--occ)
                          'cn-url (and (null node)
                                       (string-match-p constellation--scheme-re (string-trim target))
                                       (string-trim target)))
              pieces)
        (setq pos me)))
    (push (substring s pos) pieces)
    (setq s (apply #'concat (nreverse pieces)))
    (setq pos 0)
    (while (string-match constellation--emph-re s pos)
      (let* ((b (match-beginning 1)) (e (match-end 1)) (ch (aref s (match-beginning 2)))
             (inner (copy-sequence (match-string 3 s))))
        (add-face-text-property 0 (length inner)
                                (pcase ch (?* 'constellation-bold) (?/ 'constellation-italic) (?_ 'constellation-uline)
                                  (?+ 'constellation-strike) (_ 'constellation-code))
                                nil inner)
        (setq s (concat (substring s 0 b) inner (substring s e)) pos (+ b (length inner)))))
    (setq pos 0)
    (while (string-match "[<[][0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}[^]>\n]*[]>]" s pos)
      (add-face-text-property (match-beginning 0) (match-end 0) 'constellation-stamp nil s)
      (setq pos (match-end 0)))
    (add-face-text-property 0 (length s) 'constellation-text t s)
    s))

(defun constellation--note-lines (g i W)
  "Render note I as a vector of lines at most W wide.
Sets `constellation--items'."
  (let* ((nodes (constellation--g-nodes g)) (nd (aref nodes i)) (file (constellation--n-file nd))
         (WN (max 20 (- W 2))) (base (or (constellation--n-plevel nd) 0))
         out (nl 0) items pbuf (inblock nil) (indrawer nil) (lastblank t)
         (todo (constellation--todo-words)) (case-fold-search t))
    (cl-labels
        ((scan (line)
           ;; record every jumpable run (link, journal line, ...) on LINE
           (let ((p 0) (len (length line)))
             (while (< p len)
               (let ((nid (get-text-property p 'constellation-node line)) (loc (get-text-property p 'cn-loc line))
                     (url (get-text-property p 'cn-url line)) (occ (get-text-property p 'cn-occ line)))
                 (if (not (or nid loc url))
                     (setq p (1+ p))
                   (let ((e (1+ p)))
                     (while (and (< e len)
                                 (eql (get-text-property e 'constellation-node line) nid)
                                 (equal (get-text-property e 'cn-loc line) loc)
                                 (equal (get-text-property e 'cn-url line) url)
                                 (eql (get-text-property e 'cn-occ line) occ))
                       (setq e (1+ e)))
                     (let ((kind (or (get-text-property p 'cn-kind line) (cond (url 'url) (loc 'journal) (t 'link))))
                           (prev (car items)))
                       (if (and prev occ (eql (constellation--it-occ prev) occ))
                           (setf (constellation--it-segs prev)
                                 (append (constellation--it-segs prev) (list (list nl p e))))
                         (push (constellation--it-new kind nid loc url (list (list nl p e)) occ) items)))
                     (setq p e)))))))
         (emit (s)
           (let ((line (concat " " s)))
             (scan line)
             (push line out) (cl-incf nl) (setq lastblank nil)))
         (blank () (unless lastblank (push "" out) (cl-incf nl) (setq lastblank t)))
         (flush ()
           (when pbuf
             (let* ((prefix (car pbuf))
                    (txt (string-join (nreverse (cdr pbuf)) " "))
                    (styled (concat prefix (constellation--style txt g file))))
               (dolist (l (constellation--wrap styled WN (length prefix))) (emit l)))
             (setq pbuf nil)))
         (section (title)
           (blank)
           (emit (propertize (concat "─ " title " " (make-string (max 2 (- WN (length title) 3)) ?─))
                             'face 'constellation-frame))))
      (if (null (constellation--n-text nd))
          (unless (constellation--n-exists nd)
            (emit (propertize "(this note does not exist yet - e creates it)" 'face 'constellation-dim)))
        (dolist (line (constellation--n-text nd))
          (cond
           (indrawer (when (string-match-p "\\`[ \t]*:END:[ \t]*\\'" line) (setq indrawer nil)))
           ((string-match-p "\\`[ \t]*:\\(?:PROPERTIES\\|LOGBOOK\\):[ \t]*\\'" line) (flush) (setq indrawer t))
           (inblock
            (if (string-match-p "\\`[ \t]*#\\+end_" line) (setq inblock nil)
              (unless (eq inblock 'comment)
                (emit (propertize (constellation--trunc line WN) 'face 'constellation-src)))))
           ((string-match "\\`[ \t]*#\\+begin_\\([a-z]+\\)\\(?:[ \t]+\\(.*\\)\\)?" line)
            (let ((kind (downcase (match-string 1 line))) (arg (match-string 2 line)))
              (flush)
              (cond ((member kind '("quote" "verse" "center")) nil)
                    ((equal kind "comment") (setq inblock 'comment))
                    (t (setq inblock t)
                       (when (and arg (not (string-empty-p arg)))
                         (emit (propertize (concat "▎ " (car (split-string arg))) 'face 'constellation-dim)))))))
           ((string-match-p "\\`[ \t]*#\\+end_" line) nil)
           ((string-match-p "\\`[ \t]*#\\(?:\\+\\|[ \t]\\|\\'\\)" line) nil)
           ((string-match "\\`\\(\\*+\\)[ \t]+\\(.*?\\)[ \t]*\\'" line)
            (let* ((rel (max 1 (- (length (match-string 1 line)) base)))
                   (sp (constellation--split-heading (match-string 2 line)))
                   (kw (car sp)) (title (cdr sp)))
              (flush) (blank)
              (emit (concat (make-string (* 2 (1- (min rel 4))) ?\s)
                            (propertize "▸ " 'face 'constellation-bullet)
                            (if kw (propertize (concat kw " ") 'face (if (member kw (cdr todo)) 'constellation-done 'constellation-todo)) "")
                            (let ((st (constellation--style title g file)))
                              (add-face-text-property 0 (length st) (pcase rel (1 'constellation-h1) (2 'constellation-h2) (3 'constellation-h3) (_ 'constellation-h4)) nil st)
                              st)))))
           ((string-match-p "\\`[ \t]*\\(?:SCHEDULED\\|DEADLINE\\|CLOSED\\):" line)
            (flush) (emit (propertize (string-trim line) 'face 'constellation-stamp)))
           ((string-match-p "\\`[ \t]*|" line)
            (flush)
            (emit (propertize
                   (constellation--trunc
                    (let ((l (string-trim line)))
                      (if (string-match-p "\\`|[-+]+|\\'" l)
                          (concat "├" (replace-regexp-in-string "-" "─" (replace-regexp-in-string "+" "┼" (substring l 1 -1))) "┤")
                        (replace-regexp-in-string "|" "│" l)))
                    WN)
                   'face 'constellation-table)))
           ((string-match-p "\\`[ \t]*-\\{5,\\}[ \t]*\\'" line)
            (flush) (emit (propertize (make-string (min WN 40) ?─) 'face 'constellation-frame)))
           ((string-match "\\`\\([ \t]*\\)\\(?:\\([-+]\\)\\|\\([0-9]+[.)]\\)\\)[ \t]+\\(.*\\)" line)
            (let ((indent (match-string 1 line))
                  (bullet (if (match-string 2 line) "• " (concat (match-string 3 line) " ")))
                  (rest (string-trim (match-string 4 line))))
              (flush)
              (setq pbuf (list (concat indent (propertize bullet 'face 'constellation-bullet)) rest))))
           ((string-blank-p line) (flush) (blank))
           (pbuf (push (string-trim line) (cdr pbuf)))
           (t (setq pbuf (list "" (string-trim line)))))))
      (flush)
      ;; linked references
      (when (constellation--n-backs nd)
        (section (format "LINKED FROM (%d)" (length (constellation--n-backs nd))))
        (dolist (b (seq-take (constellation--n-backs nd) 15))
          (let ((src (aref nodes (car b))))
            (emit (concat (propertize "• " 'face 'constellation-bullet)
                          (propertize (constellation--n-title src) 'face 'constellation-nbr 'constellation-node (car b)
                          'cn-kind 'back 'cn-loc (and (nth 2 b) (nth 3 b) (cons (nth 2 b) (nth 3 b))))))
            (unless (string-empty-p (nth 1 b))
              (emit (concat "    " (propertize (constellation--trunc (constellation--wrap-first (nth 1 b)) (- WN 6)) 'face 'constellation-dim)))))))
      (when (constellation--n-snips nd)
        (section "IN THE JOURNAL")
        (dolist (s (seq-take (constellation--n-snips nd) 10))
          (let ((loc (and (nth 2 s) (nth 3 s) (cons (nth 2 s) (nth 3 s)))))
            (emit (propertize
                   (concat (propertize (if (string-empty-p (car s)) "          " (car s)) 'face 'constellation-stamp)
                           "  " (propertize (constellation--trunc (nth 1 s) (- WN 14)) 'face 'constellation-text))
                   'cn-loc loc 'cn-kind 'journal))))))
    (setq constellation--items (vconcat (nreverse items)))
    (vconcat (nreverse out))))

(defun constellation--wrap-first (s) (car (split-string s "\n")))

(defun constellation--note-for (g i W)
  (let ((key (list i W (constellation--g-sig g))))
    (unless (equal (car constellation--note-cache) key)
      (let ((lines (constellation--note-lines g i W)))
        (setq constellation--note-cache
              (list key lines constellation--items))))
    (setq constellation--items (nth 2 constellation--note-cache))
    (nth 1 constellation--note-cache)))

(defun constellation--note-line (nlines li)
  "Line LI of NLINES, with the picked item highlighted."
  (let* ((l (aref nlines li)) (it (constellation--item-cur)) (seg (and it (assq li (constellation--it-segs it)))))
    (if (null seg) l
      (let ((c (copy-sequence l)))
        (add-face-text-property (nth 1 seg) (min (length c) (nth 2 seg)) 'constellation-pick nil c)
        c))))

;;;; Rendering ------------------------------------------------------------

(defun constellation--render ()
  (constellation--no-wrap)
  (let* ((inhibit-read-only t)
         (g constellation--graph)
         (nodes (constellation--g-nodes g)) (n (length nodes)) (edges (constellation--g-edges g))
         (dm (constellation--dims)) (W (nth 0 dm)) (LW (nth 1 dm)) (WG (nth 2 dm))
         (R (nth 3 dm)) (H (nth 4 dm)) (NH (nth 5 dm))
         (sel (if (> n 0) (min constellation--sel (1- n)) 0))
         (seln (and (> n 0) (aref nodes sel)))
         (isn (make-vector n nil))
         (chars (make-vector H nil)) (faces (make-vector H nil)) (ids (make-vector H nil))
         (bmask (make-vector H nil)) (bprio (make-vector H nil))
         (occ (make-hash-table :test 'eql)) (lab (make-hash-table :test 'eql))
         (win (get-buffer-window (current-buffer)))
         (hw (/ WG 2.0))
         (maxlab (min 26 (max 12 (/ WG 5))))
         shown bg sel-edges)
    (constellation--clear-packets)
    (setq constellation--sel sel constellation--dims-last dm constellation--cellbase (1+ LW) constellation--stride (1+ W))
    (constellation--ensure-list)
    (constellation--reset-screen nodes)
    (when seln
      (dolist (a (constellation--n-nbrs seln)) (aset isn (car a) t))
      (let ((pr (constellation--project-orbit g sel WG (max H 14))))
        (setq shown (car pr) bg (cdr pr)))
      (when (and constellation--cur (not (memq constellation--cur constellation--ring1))) (setq constellation--cur nil))
      (setq sel-edges (seq-take (sort (copy-sequence (constellation--n-inc seln))
                                      (lambda (a b) (> (constellation--ew a) (constellation--ew b))))
                                60)))
    (dotimes (y H)
      (aset chars y (make-string WG ?\s t))
      (aset faces y (make-vector WG nil))
      (aset ids y (make-vector WG nil))
      (aset bmask y (make-vector WG 0))
      (aset bprio y (make-vector WG 0)))
    (when (> H 0)
      (cl-labels
          ((put (x y ch face &optional id)
             (when (and (>= x 0) (< x WG) (>= y 0) (< y H))
               (aset (aref chars y) x ch) (aset (aref faces y) x face)
               (when id (aset (aref ids y) x id))))
           (key (x y) (+ (* y 4096) x))
           (text (x y s face)
             (dotimes (c (length s))
               (when (and (< (+ x c) WG) (eq (aref (aref chars y) (+ x c)) ?\s))
                 (put (+ x c) y (aref s c) face))))
           (bline (x0 y0 x1 y1 prio dotted)
             (let* ((dx (- x1 x0)) (dy (- y1 y0)) (len (max (abs dx) (abs dy))))
               (dotimes (s (1+ len))
                 (when (or (not dotted) (< (% s 4) 2))
                   (let* ((px (if (zerop len) x0 (+ x0 (round (/ (* dx s) (float len))))))
                          (py (if (zerop len) y0 (+ y0 (round (/ (* dy s) (float len))))))
                          (cx (ash px -1)) (cy (/ py 4)))
                     (when (and (>= px 0) (>= py 0) (< cx WG) (< cy H))
                       (let ((mr (aref bmask cy)) (pr (aref bprio cy)))
                         (aset mr cx (logior (aref mr cx) (aref constellation--bits (+ (* 2 (% py 4)) (% px 2)))))
                         (when (> prio (aref pr cx)) (aset pr cx prio)))))))))
           (bedge (e hot)
             (let ((a (aref nodes (nth 0 e))) (b (aref nodes (nth 1 e))))
               (when (and (constellation--n-shown a) (constellation--n-shown b) (< (constellation--n-gy a) H) (< (constellation--n-gy b) H))
                 (let ((linkp (> (+ (nth 2 e) (nth 3 e)) 0)))
                   (bline (1+ (* 2 (constellation--n-gx a))) (+ 2 (* 4 (constellation--n-gy a)))
                          (1+ (* 2 (constellation--n-gx b))) (+ 2 (* 4 (constellation--n-gy b)))
                          (if hot (if linkp 3 2) 1) (not linkp))))))
           (arrow (e)
             (let* ((rel (constellation--rel e sel)) (oi (if (= (nth 0 e) sel) (nth 1 e) (nth 0 e)))
                    (o (aref nodes oi)))
               (when (and (memq rel '(out in)) (constellation--n-shown o) (< (constellation--n-gy o) H)
                          (zerop (if (eq rel 'out) (if (= (nth 0 e) sel) (nth 3 e) (nth 2 e))
                                   (if (= (nth 0 e) sel) (nth 2 e) (nth 3 e)))))
                 (let* ((p (constellation--line (constellation--n-gx seln) (constellation--n-gy seln) (constellation--n-gx o) (constellation--n-gy o)))
                        (p (if (eq rel 'out) (reverse p) p)))
                   (when (>= (length p) 7)
                     (let* ((c (nth 3 p)) (prev (nth 2 p))
                            (dx (- (car prev) (car c))) (dy (- (cdr prev) (cdr c))))
                       (unless (gethash (key (car c) (cdr c)) occ)
                         (put (car c) (cdr c)
                              (cond ((/= dx 0) (if (> dx 0) ?> ?<)) ((> dy 0) ?v) (t ?^))
                              'constellation-edge-hot)
                         (puthash (key (car c) (cdr c)) t lab))))))))
           (glyph (nd) (let ((deg (constellation--n-deg nd)))
                         (cond ((not (constellation--n-exists nd)) "?") ((= deg 0) "·") ((<= deg 2) "o") ((<= deg 5) "O")
                               ((<= deg 9) "(O)") (t "(@)"))))
           (face-of (i nd)
             (cond ((= i sel) 'constellation-sel) ((eq i constellation--cur) 'constellation-cur)
                   ((aref isn i) 'constellation-nbr) (t (constellation--heat-face nd))))
           (label (i maxlen)
             (let* ((nd (aref nodes i)) (x (constellation--n-gx nd)) (y (constellation--n-gy nd))
                    (txt (constellation--trunc (constellation--n-title nd) maxlen)) (len (length txt))
                    (hwid (if (> (constellation--n-deg nd) 5) 1 0)) (pad (if (= i sel) 2 1))
                    (right (+ x hwid pad 1)) (left (- x hwid pad len))
                    (sides (if (< x hw) (list left right) (list right left)))
                    (face (face-of i nd)) (done nil))
               (when (< y H)
                 (dolist (dy '(0 -1 1))
                   (dolist (x0 sides)
                     (let ((yy (+ y dy)))
                       (when (and (not done) (>= x0 0) (<= (+ x0 len) WG) (>= yy 0) (< yy H)
                                  (cl-loop for c from x0 below (+ x0 len) never (gethash (key c yy) occ))
                                  (cl-loop for c from (1- x0) to (+ x0 len) never (gethash (key c yy) lab)))
                         (dotimes (c len) (put (+ x0 c) yy (aref txt c) face i))
                         (cl-loop for c from (1- x0) to (+ x0 len) do (puthash (key c yy) t lab))
                         (setf (constellation--n-lab nd) t)
                         (setq done t))))))
               done)))
        (cond
         ((= n 0) (text 3 (/ H 2) "No notes found.  Set `constellation-sources'." 'constellation-hot))
         (t
          (dolist (e bg) (bedge e nil))
          (dolist (e sel-edges) (bedge e t))
          (dotimes (y H)
            (dotimes (x WG)
              (let ((m (aref (aref bmask y) x)))
                (when (> m 0)
                  (put x y (+ #x2800 m)
                       (pcase (aref (aref bprio y) x) (1 'constellation-edge) (2 'constellation-co-hot) (_ 'constellation-edge-hot)))))))
          (dolist (i shown)
            (let ((nd (aref nodes i)))
              (when (< (constellation--n-gy nd) H)
                (let* ((c (constellation--n-gx nd)) (r (constellation--n-gy nd))
                       (gl (glyph nd)) (f (face-of i nd)) (gw (length gl)) (x0 (- c (/ gw 2))))
                  (dotimes (k gw) (put (+ x0 k) r (aref gl k) f i) (puthash (key (+ x0 k) r) t occ))
                  (when (= i sel)
                    (put (1- x0) r ?> 'constellation-flank i) (put (+ x0 gw) r ?< 'constellation-flank i)
                    (puthash (key (1- x0) r) t occ) (puthash (key (+ x0 gw) r) t occ))))))
          (dolist (e sel-edges) (arrow e))
          (label sel (min 30 (+ maxlab 4)))
          (dolist (i constellation--ring1) (label i maxlab))
          (dolist (i shown)
            (unless (or (= i sel) (memq i constellation--ring1)) (label i (max 10 (- maxlab 6)))))
          (pcase-let ((`(,gi ,go ,gc) constellation--groups))
            (when (> gi 0) (text 1 0 "<- links in" 'constellation-dim))
            (when (> go 0) (let ((s "links out ->")) (text (max 0 (- WG (length s) 1)) 0 s 'constellation-dim)))
            (when (> gc 0)
              (let ((s ": mentioned together :"))
                (text (max 0 (/ (- WG (length s)) 2)) 0 s 'constellation-dim)
                (when (> gc 1) (text (max 0 (/ (- WG (length s)) 2)) (1- H) s 'constellation-dim))))
            (when (= (+ gi go gc) 0)
              (text (max 0 (- (/ WG 2) 10)) (+ 2 (/ H 2)) "(no connections yet)" 'constellation-dim)))
          (dotimes (y H)
            (dotimes (x WG)
              (when (= (aref (aref chars y) x) ?\s)
                (let ((h (logxor (* (1+ x) 73856093) (* (1+ y) 19349663))))
                  (when (zerop (% h 67))
                    (put x y (nth (% (/ h 67) 3) '(?· ?. ?+)) 'constellation-star))))))))))
    ;; ---- note pane
    (let* ((nlines (if (and seln (> NH 0)) (constellation--note-for g sel (- WG 0))
                    (progn (setq constellation--items []) [])))
           (_fix (when (and constellation--item (>= constellation--item (length constellation--items)))
                   (setq constellation--item nil)))
           (content-rows (max 0 (1- NH)))
           (maxscroll (max 0 (- (length nlines) content-rows))))
      (setq constellation--nscroll (max 0 (min constellation--nscroll maxscroll)))
      ;; ---- emit buffer
      (erase-buffer)
      (let* ((lst constellation--list) (len (length lst)) (pos (if seln (aref constellation--listpos sel) -1)))
        (insert (propertize " CONSTELLATION " 'face 'constellation-title)
                (propertize (format ":: %d notes  %d links  %d clusters :: sort %s%s :: %s"
                                    n (length edges) (constellation--g-clusters g)
                                    (pcase constellation--sort ('recent "recent") ('links "most linked") (_ "A-Z"))
                                    (if (string-empty-p constellation--filter) "" (format "  filter \"%s\"" constellation--filter))
                                    (if (> len 0) (format "%d/%d" (1+ (max 0 pos)) len) "none"))
                            'face 'constellation-hud)
                "\n")
        (when (>= pos 0)
          (unless (and (>= pos constellation--top) (< pos (+ constellation--top R)))
            (setq constellation--top (max 0 (- pos (/ R 3))))))
        (setq constellation--top (max 0 (min constellation--top (max 0 (- len R)))))
        (setq constellation--origin (point))
        (dotimes (y R)
          (let ((li (+ constellation--top y)))
            (insert (if (< li len)
                        (let* ((i (aref lst li)) (nd (aref nodes i)))
                          (constellation--list-row nd i LW
                                          (cond ((= i sel) 'constellation-sel) ((eq i constellation--cur) 'constellation-cur)
                                                ((aref isn i) 'constellation-nbr) (t (constellation--heat-face nd)))
                                          (= i sel)))
                      (propertize (if (and (= li 0) (= len 0)) (constellation--fit " (no match)" LW) (make-string LW ?\s))
                                  'face 'constellation-dim))))
          (insert (propertize "|" 'face 'constellation-frame))
          (if (< y H)
              (let ((x 0) (row (aref chars y)) (fr (aref faces y)) (ir (aref ids y)))
                (while (< x WG)
                  (let ((f (aref fr x)) (id (aref ir x)) (x2 (1+ x)))
                    (while (and (< x2 WG) (eq (aref fr x2) f) (eql (aref ir x2) id)) (setq x2 (1+ x2)))
                    (let ((s (substring row x x2)))
                      (add-text-properties 0 (length s)
                                           (append (and f (list 'face f)) (and id (list 'constellation-node id)))
                                           s)
                      (insert s))
                    (setq x x2))))
            (let ((k (- y H)))
              (if (= k 0)
                  (insert (constellation--note-bar seln WG nlines content-rows))
                (let ((li (+ constellation--nscroll (1- k))))
                  (when (< li (length nlines)) (insert (constellation--note-line nlines li)))))))
          (insert "\n"))))
    (constellation--insert-info g sel W)
    (when (> H 0) (when seln (constellation--spawn nodes sel-edges sel occ WG H)))
    (goto-char (point-min))
    (when win (set-window-point win (point-min)) (set-window-start win (point-min) t))))

(defun constellation--note-bar (nd WG nlines rows)
  (if (null nd) ""
    (let* ((total (length nlines)) (a (1+ constellation--nscroll)) (b (min total (+ constellation--nscroll rows)))
           (right (if (> total rows) (format " %d-%d/%d " a b total) ""))
           (left (concat " ▌ " (constellation--n-title nd) (if (constellation--n-exists nd) "" "  (ghost)"))))
      (concat (propertize (constellation--fit left (- WG (length right))) 'face 'constellation-title)
              (propertize right 'face 'constellation-dim)))))

(defun constellation--key (k d)
  (concat (propertize k 'face 'constellation-key) (propertize (concat " " d "  ") 'face 'constellation-dim)))

(defun constellation--insert-info (g sel W)
  (let ((nodes (constellation--g-nodes g)))
    (cl-flet ((line (s &optional face) (insert (propertize (constellation--fit s W) 'face (or face 'constellation-hud)) "\n")))
      (insert (propertize (make-string W ?-) 'face 'constellation-frame) "\n")
      (if (= (length nodes) 0)
          (progn (line "") (line ""))
        (let* ((nd (aref nodes sel))
               (cos (cl-count-if (lambda (e) (> (nth 4 e) 0)) (constellation--n-inc nd)))
               (title (constellation--fit (concat " > " (constellation--n-title nd)) (min 40 (/ W 2))))
               (stats (format "  out %d  in %d  co %d  mentions %d  last %s"
                              (length (constellation--n-outs nd)) (length (constellation--n-ins nd)) cos
                              (constellation--n-mentions nd) (or (constellation--n-last nd) "-")))
               (cur (and constellation--cur (aref nodes constellation--cur)))
               (it (constellation--item-cur)))
          (insert (propertize title 'face 'constellation-title)
                  (propertize (constellation--fit stats (- W (length title))) 'face 'constellation-hud) "\n")
          (if it
              (line (constellation--item-describe it nodes) 'constellation-cur)
           (if cur
              (line (format " => %s   last %s   (RET dive)" (constellation--n-title cur) (or (constellation--n-last cur) "-")) 'constellation-cur)
            (line (format " %s%s" (if (constellation--n-file nd) (abbreviate-file-name (constellation--n-file nd)) "(no file yet)")
                          (if (constellation--n-line nd) (format ":%d" (constellation--n-line nd)) ""))
                  'constellation-dim))))))
    (insert " "
            (constellation--key "j/k" "notes") (constellation--key "h/l" "chart") (constellation--key "J/K" "pick")
            (constellation--key "m" "journal") (constellation--key "o" "open") (constellation--key "u" "back")
            (constellation--key "/" "filter") (constellation--key "s" "sort") (constellation--key "v" "layout")
            (constellation--key "e" "edit") (constellation--key "g" "refresh") (constellation--key "q" "quit"))))

;;;; Animation ------------------------------------------------------------

(defun constellation--tick (buf)
  (cond
   ((not (buffer-live-p buf)) (cancel-function-timers #'constellation--tick))
   ((get-buffer-window buf)
    (with-current-buffer buf
      (dolist (p constellation--packets)
        (let* ((path (nth 1 p)) (pos (mod (1+ (nth 2 p)) (length path)))
               (c (aref path pos)) (q (constellation--cell (car c) (cdr c))))
          (setf (nth 2 p) pos)
          (move-overlay (car p) q (1+ q))))))))

;;;; Commands -------------------------------------------------------------

(defconst constellation--wrapping-modes
  '(visual-line-mode visual-fill-column-mode adaptive-wrap-prefix-mode
    olivetti-mode)
  "Minor modes that re-wrap or re-flow lines and would break the graph.")

(defun constellation--no-wrap ()
  "Never wrap lines in this buffer; the graph is drawn on a fixed grid.
Globalized modes such as `global-visual-line-mode' switch themselves
on after the major mode body has run, so this is called again from
`constellation' and on every render."
  (dolist (m constellation--wrapping-modes)
    (when (and (fboundp m) (boundp m) (symbol-value m))
      (funcall m -1)))
  (setq truncate-lines t
        word-wrap nil
        wrap-prefix nil
        line-prefix nil))

(defun constellation--select (i &optional nohist)
  (unless (or nohist (= i constellation--sel)) (push constellation--sel constellation--hist))
  (unless (= i constellation--sel) (setq constellation--nscroll 0))
  (setq constellation--sel i constellation--cur nil constellation--item nil)
  (constellation--render))

(defun constellation--move-list (delta)
  (constellation--ensure-list)
  (let ((len (length constellation--list)))
    (when (> len 0)
      (let* ((pos (aref constellation--listpos constellation--sel))
             (new (max 0 (min (1- len) (+ (if (< pos 0) (if (> delta 0) -1 len) pos) delta)))))
        (constellation--select (aref constellation--list new) t)))))

(defun constellation-list-next () "Next note in the list." (interactive) (constellation--move-list 1))
(defun constellation-list-prev () "Previous note in the list." (interactive) (constellation--move-list -1))
(defun constellation-list-first () "First note." (interactive) (constellation--move-list -100000))
(defun constellation-list-last () "Last note." (interactive) (constellation--move-list 100000))

(defun constellation--scroll (delta)
  (setq constellation--nscroll (max 0 (+ constellation--nscroll delta)))
  (constellation--render))

(defun constellation-scroll-down () "Scroll the note down." (interactive)
       (constellation--scroll (max 3 (- (nth 5 (constellation--dims)) 3))))
(defun constellation-scroll-up () "Scroll the note up." (interactive)
       (constellation--scroll (- (max 3 (- (nth 5 (constellation--dims)) 3)))))
(defun constellation-scroll-line-down () "Scroll the note one line." (interactive) (constellation--scroll 1))
(defun constellation-scroll-line-up () "Scroll the note one line back." (interactive) (constellation--scroll -1))

(defun constellation--ring-step (dir)
  (if (null constellation--ring1)
      (message "This note has no connections yet.")
    (let* ((pos (cl-position constellation--cur constellation--ring1))
           (new (if pos (mod (+ pos dir) (length constellation--ring1)) (if (> dir 0) 0 (1- (length constellation--ring1))))))
      (setq constellation--cur (nth new constellation--ring1) constellation--item nil)
      (constellation--render))))

(defun constellation-ring-next () "Highlight the next neighbour." (interactive) (constellation--ring-step 1))
(defun constellation-ring-prev () "Highlight the previous neighbour." (interactive) (constellation--ring-step -1))

(defun constellation-enter ()
  "Act on the picked note item, else dive into the highlighted neighbour.
Picked link or linked-from entry: dive into that note.  Picked journal
mention: open the journal file at that line.  With nothing picked or
highlighted, edit the selected note."
  (interactive)
  (let ((it (constellation--item-cur)))
    (cond (it (constellation--item-act it nil))
          (constellation--cur (constellation--select constellation--cur))
          (t (constellation--visit)))))

;;;; Jumping from the note pane -------------------------------------------

(defun constellation--item-cur ()
  (and constellation--item (< constellation--item (length constellation--items))
       (aref constellation--items constellation--item)))

(defun constellation--item-row (it) (car (car (constellation--it-segs it))))

(defun constellation--item-describe (it nodes)
  (let* ((i (constellation--it-node it)) (nd (and i (aref nodes i)))
         (loc (constellation--it-loc it))
         (where (if loc (format "%s:%d" (file-name-nondirectory (car loc)) (cdr loc)) "")))
    (pcase (constellation--it-kind it)
      ('journal (format " => journal %s   (RET open)" where))
      ('url (format " => %s   (RET open)" (constellation--it-url it)))
      ('back (format " => linked from %s  %s   (RET dive  o open at link)" (constellation--n-title nd) where))
      (_ (format " => link to %s   (RET dive  o open note)" (constellation--n-title nd))))))

(defun constellation--open-at (file line)
  "Show FILE at LINE in the other window."
  (if (not (and file (file-readable-p file)))
      (message "That file is not available.")
    (switch-to-buffer-other-window (find-file-noselect file))
    (widen) (goto-char (point-min)) (forward-line (max 0 (1- (or line 1))))
    (when (derived-mode-p 'org-mode) (org-reveal))
    (recenter 3)))

(defun constellation--open-url (target)
  "Open the external link TARGET the way org would."
  (condition-case err
      (if (fboundp 'org-link-open-from-string)
          (org-link-open-from-string (format "[[%s]]" target))
        (browse-url target))
    (error (message "Cannot open %s: %s" target (error-message-string err)))))

(defun constellation--item-act (it open-source)
  (let ((loc (constellation--it-loc it)) (node (constellation--it-node it)))
    (pcase (constellation--it-kind it)
      ('journal (constellation--open-at (car loc) (cdr loc)))
      ('url (constellation--open-url (constellation--it-url it)))
      ('back (if (and open-source loc) (constellation--open-at (car loc) (cdr loc)) (constellation--select node)))
      (_ (if open-source (constellation--visit nil node) (constellation--select node))))))

(defun constellation--show-note ()
  "Make sure the note pane is visible (it is not in graph-only layout)."
  (when (= (nth 5 (constellation--dims)) 0)
    (setq constellation--layout 'split)
    (constellation--render)))

(defun constellation--item-goto (idx)
  (let* ((it (aref constellation--items idx))
         (rows (max 1 (1- (nth 5 (constellation--dims)))))
         (row (constellation--item-row it)))
    (when (or (< row constellation--nscroll) (>= row (+ constellation--nscroll rows)))
      (setq constellation--nscroll (max 0 (- row (/ rows 2)))))
    (setq constellation--item idx constellation--cur nil)
    (constellation--render)))

(defun constellation--item-step (dir)
  (constellation--show-note)
  (let* ((its constellation--items) (n (length its)))
    (if (= n 0)
        (message "Nothing to jump to in this note.")
      (let* ((rows (max 1 (1- (nth 5 (constellation--dims)))))
             (idx (cond
                   (constellation--item (mod (+ constellation--item dir) n))
                   ((> dir 0) (or (cl-position-if (lambda (it) (>= (constellation--item-row it) constellation--nscroll)) its) 0))
                   (t (or (cl-position-if (lambda (it) (< (constellation--item-row it) (+ constellation--nscroll rows))) its :from-end t)
                          (1- n))))))
        (constellation--item-goto idx)))))

(defun constellation-item-next ()
  "Pick the next link / linked-from / journal entry in the note pane."
  (interactive) (constellation--item-step 1))
(defun constellation-item-prev ()
  "Pick the previous link / linked-from / journal entry in the note pane."
  (interactive) (constellation--item-step -1))

(defun constellation-item-journal ()
  "Pick the next journal mention of this note (RET then opens it)."
  (interactive)
  (constellation--show-note)
  (let* ((its constellation--items) (from (if constellation--item (1+ constellation--item) 0))
         (idx (or (cl-position 'journal its :key #'constellation--it-kind :start (min from (length its)))
                  (cl-position 'journal its :key #'constellation--it-kind))))
    (if idx (constellation--item-goto idx) (message "No journal mentions for this note."))))

(defun constellation-open-source ()
  "Open the picked item in its org file; with none picked, edit the note."
  (interactive)
  (let ((it (constellation--item-cur)))
    (if it (constellation--item-act it t) (constellation--visit))))

(defun constellation-back ()
  (interactive)
  (if constellation--hist
      (progn (setq constellation--sel (pop constellation--hist) constellation--cur nil constellation--item nil constellation--nscroll 0) (constellation--render))
    (message "No history.")))

(defun constellation--fix-selection ()
  (constellation--ensure-list)
  (when (and (> (length constellation--list) 0) (< (aref constellation--listpos constellation--sel) 0))
    (setq constellation--sel (aref constellation--list 0) constellation--cur nil constellation--item nil constellation--nscroll 0))
  (setq constellation--top 0)
  (constellation--render))

(defun constellation-filter ()
  "Filter the list as you type.  Empty input clears it."
  (interactive)
  (let ((buf (current-buffer)) (old constellation--filter) (ok nil))
    (unwind-protect
        (progn
          (minibuffer-with-setup-hook
              (lambda ()
                (add-hook 'post-command-hook
                          (lambda ()
                            (when (buffer-live-p buf)
                              (let ((s (minibuffer-contents-no-properties)))
                                (with-current-buffer buf
                                  (unless (equal s constellation--filter)
                                    (setq constellation--filter s)
                                    (constellation--fix-selection))))))
                          nil t))
            (read-from-minibuffer "Filter notes: " old))
          (setq ok t))
      (unless ok (with-current-buffer buf (setq constellation--filter old) (constellation--fix-selection))))))

(defun constellation-sort ()
  "Cycle the list order: recent, most linked, A-Z."
  (interactive)
  (setq constellation--sort (pcase constellation--sort ('recent 'links) ('links 'az) (_ 'recent)))
  (constellation--ensure-list)
  (constellation--render))

(defun constellation-layout-cycle ()
  "Cycle the right side: graph+note, note only, graph only."
  (interactive)
  (setq constellation--layout (pcase constellation--layout ('split 'note) ('note 'graph) (_ 'split)))
  (constellation--render))

(defun constellation--default-sel (g)
  (let ((best 0) (nodes (constellation--g-nodes g)))
    (dotimes (i (length nodes))
      (let ((a (aref nodes i)) (b (aref nodes best)))
        (when (or (string> (or (constellation--n-last a) "") (or (constellation--n-last b) ""))
                  (and (equal (constellation--n-last a) (constellation--n-last b)) (> (constellation--n-deg a) (constellation--n-deg b))))
          (setq best i))))
    best))

(defun constellation--reload ()
  (let* ((old (and constellation--graph (> (length (constellation--g-nodes constellation--graph)) 0)
                   (constellation--n-title (aref (constellation--g-nodes constellation--graph) constellation--sel))))
         (g (constellation--parse)))
    (setq constellation--graph g constellation--list-key nil constellation--note-cache nil)
    (setq constellation--sel (or (and old (cl-position old (constellation--g-nodes g) :key #'constellation--n-title :test #'equal))
                        (constellation--default-sel g))
          constellation--cur nil constellation--item nil constellation--hist nil)
    (constellation--fix-selection)))

(defun constellation-sync () "Re-read the org files." (interactive)
       (constellation--reload) (message "Re-read %d notes" (length (constellation--g-nodes constellation--graph))))

(defun constellation--create (title)
  "Create the missing note TITLE.  Returns non-nil when done."
  (cond
   ((not (y-or-n-p (format "Create note \"%s\"? " title))) nil)
   (t (let* ((files (constellation--files)))
        (if (= (length files) 1)
            (with-current-buffer (find-file-noselect (car files))
              (save-excursion (goto-char (point-max)) (unless (bolp) (insert "\n"))
                              (insert (format "%s %s\n" (make-string (or constellation-heading-level 1) ?*) title)))
              (save-buffer) t)
          (let* ((dir (let ((s (or (car (if (listp constellation-sources) constellation-sources (list constellation-sources)))
                                   org-directory default-directory)))
                        (file-name-as-directory (expand-file-name s))))
                 (dir (if (file-directory-p dir) dir (file-name-directory (directory-file-name dir))))
                 (f (expand-file-name (concat (replace-regexp-in-string "[^[:alnum:]_-]+" "-" (downcase title)) ".org") dir)))
            (with-temp-file f (insert (format "#+title: %s\n\n" title)))
            t))))))

(defun constellation--visit (&optional same-window index)
  "Edit the highlighted (else selected) note in its org file."
  (let* ((nodes (constellation--g-nodes constellation--graph)) (nd (aref nodes (or index constellation--cur constellation--sel))))
    (when (or (constellation--n-exists nd) (constellation--create (constellation--n-title nd)))
      (when (null (constellation--n-exists nd)) (constellation-sync))
      (let* ((nd2 (or (cl-find (constellation--n-title nd) (constellation--g-nodes constellation--graph) :key #'constellation--n-title :test #'equal) nd))
             (file (or (constellation--n-file nd2) (car (constellation--files)))) (buf (find-file-noselect file)))
        (if same-window (switch-to-buffer buf) (switch-to-buffer-other-window buf))
        (widen) (goto-char (point-min))
        (when (and (eq (constellation--n-kind nd2) 'heading) (constellation--n-line nd2))
          (forward-line (1- (constellation--n-line nd2)))
          (unless (looking-at-p (concat "\\*+[ \t]+.*" (regexp-quote (constellation--n-title nd2))))
            (goto-char (point-min))
            (unless (re-search-forward (format "^\\*+ +.*%s" (regexp-quote (constellation--n-title nd2))) nil t)
              (goto-char (point-min))))
          (beginning-of-line))
        (when (derived-mode-p 'org-mode) (org-reveal))
        (recenter 3)))))

(defun constellation-edit () "Edit the note in another window." (interactive) (constellation--visit))

(defun constellation-click (ev)
  "Click a link to dive into it; click a journal mention to open it."
  (interactive "e")
  (let* ((pos (posn-point (event-end ev)))
         (id (and pos (get-text-property pos 'constellation-node)))
         (loc (and pos (get-text-property pos 'cn-loc)))
         (url (and pos (get-text-property pos 'cn-url))))
    (cond (id (constellation--select id))
          (loc (constellation--open-at (car loc) (cdr loc)))
          (url (constellation--open-url url)))))

(defun constellation-click-open (ev)
  (interactive "e")
  (let* ((pos (posn-point (event-end ev)))
         (external (and pos (or (get-text-property pos 'cn-loc) (get-text-property pos 'cn-url)))))
    (constellation-click ev)
    (unless external (constellation--visit))))

(defun constellation-quit ()
  (interactive)
  (let ((wc constellation--wconf))
    (constellation--clear-packets)
    (bury-buffer)
    (if wc (set-window-configuration wc) (quit-window))))

(defun constellation-help ()
  (interactive)
  (message "j/k notes | h/l chart | J/K pick | RET follow | o open in file | m journal | u back | / filter | s sort | v layout | e edit | g refresh | q quit"))

(defun constellation--on-resize ()
  (when (and constellation--graph (derived-mode-p 'constellation-mode)
             (get-buffer-window (current-buffer))
             (not (equal (constellation--dims) constellation--dims-last)))
    (constellation--render)))

(defvar constellation-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m special-mode-map)
    (dolist (b '(("<down>" . constellation-list-next) ("j" . constellation-list-next)
                 ("<up>" . constellation-list-prev) ("k" . constellation-list-prev)
                 ("<home>" . constellation-list-first) ("<end>" . constellation-list-last)
                 ("<wheel-down>" . constellation-scroll-line-down) ("<wheel-up>" . constellation-scroll-line-up)
                 ("<next>" . constellation-scroll-down) ("<prior>" . constellation-scroll-up)
                 ("C-v" . constellation-scroll-down) ("M-v" . constellation-scroll-up)
                 ("<right>" . constellation-ring-next) ("l" . constellation-ring-next) ("TAB" . constellation-ring-next)
                 ("<left>" . constellation-ring-prev) ("h" . constellation-ring-prev) ("<backtab>" . constellation-ring-prev)
                 ("J" . constellation-item-next) ("K" . constellation-item-prev) ("m" . constellation-item-journal)
                 ("RET" . constellation-enter) ("o" . constellation-open-source) ("e" . constellation-edit)
                 ("u" . constellation-back) ("/" . constellation-filter) ("s" . constellation-sort)
                 ("v" . constellation-layout-cycle) ("g" . constellation-sync)
                 ("?" . constellation-help) ("q" . constellation-quit)))
      (define-key m (kbd (car b)) (cdr b)))
    (define-key m [mouse-1] #'constellation-click)
    (define-key m [double-mouse-1] #'constellation-click-open)
    m))

(define-derived-mode constellation-mode special-mode "Constellation"
  "Major mode for the org notes browser."
  (setq-local truncate-lines t word-wrap nil
              cursor-type nil show-trailing-whitespace nil
              global-hl-line-mode nil scroll-conservatively 101 scroll-margin 0
              auto-hscroll-mode nil line-spacing 0 buffer-undo-list t)
  (when (bound-and-true-p display-line-numbers-mode) (display-line-numbers-mode -1))
  (when (bound-and-true-p hl-line-mode) (hl-line-mode -1))
  (apply #'face-remap-add-relative 'default
         (if (eq (frame-parameter nil 'background-mode) 'dark)
             '(:background "#050a06" :foreground "#2f8f4f")
           '(:background "#f3f8f4" :foreground "#3a7a50")))
  (when (timerp constellation--timer) (cancel-timer constellation--timer))
  (setq constellation--timer (run-with-timer 0.2 0.07 #'constellation--tick (current-buffer)))
  (add-hook 'kill-buffer-hook (lambda () (when (timerp constellation--timer) (cancel-timer constellation--timer))) nil t)
  (add-hook 'window-configuration-change-hook #'constellation--on-resize nil t))

;;;###autoload
(defun constellation ()
  "Open the notes browser."
  (interactive)
  (let ((wc (current-window-configuration))
        (buf (get-buffer-create "*constellation*")))
    (switch-to-buffer buf)
    (delete-other-windows)
    (unless (derived-mode-p 'constellation-mode) (constellation-mode))
    (constellation--no-wrap)
    (setq constellation--wconf wc)
    (constellation--reload)))

(provide 'constellation)
;;; constellation.el ends here
