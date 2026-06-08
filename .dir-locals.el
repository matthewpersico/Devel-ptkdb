
((perl-mode
  (eval . (setenv "PERL5LIB"
            (concat (expand-file-name "lib" (locate-dominating-file
                                              default-directory
                                              ".dir-locals.el"))
                    path-separator
                    (or (getenv "PERL5LIB") "")))))
 (cperl-mode
  (eval . (setenv "PERL5LIB"
            (concat (expand-file-name "lib" (locate-dominating-file
                                              default-directory
                                              ".dir-locals.el"))
                    path-separator
                    (or (getenv "PERL5LIB") ""))))))
