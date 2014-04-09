#  File     : Makefile
#  RCS      : $Id: Makefile,v 1.1 2003/03/30 13:43:53 schachte Exp $
#  Author   : Peter Schachte

VERSION=0.1

all:	test

%.pdf:	%.tex
	rubber -m pdftex $<

%.ps:	%.tex
	rubber -m dvips $<

%.hs:	%.y
	happy -g $<

wybemk:	*.hs Version.lhs Parser.hs
	ghc -fwarn-incomplete-patterns --make $@

.PHONY:	info

info:  Parser.info

%.info:	%.y
	happy -i -g $<

doc:	*.hs
	rm -rf $@
	haddock -h -o $@ *.hs

Version.lhs:	*.hs
	@echo "Generating Version.lhs for version $(VERSION)"
	@rm -f $@
	@printf "Version.lhs automatically generated:  DO NOT EDIT\n" > $@
	@printf "\n" >> $@
	@printf "> module Version (version,buildDate) where\n" >> $@
	@printf "> version :: String\n> version = \"%s\"\n" "$(VERSION)" >> $@
	@printf "> buildDate :: String\n> buildDate = \"%s\"\n" "`date`" >> $@

TESTCASES = $(wildcard test-cases/*.wybe)

test:	wybemk
	@rm -f ERRS ; touch ERRS
	@for f in $(TESTCASES) ; do \
	    printf "%-40s ... " $$f ; \
	    out=`echo "$$f" | sed 's/.wybe$$/.out/'` ; \
	    exp=`echo "$$f" | sed 's/.wybe$$/.exp/'` ; \
	    targ=`echo "$$f" | sed 's/.wybe$$/.o/'` ; \
	    ./wybemk -v -f $$targ > $$out 2>&1 ; \
	    if [ ! -r $$exp ] ; then \
		printf "[31mNEW TEST[39m\n" ; \
	    elif diff -u $$exp $$out >> ERRS 2>&1 ; then \
		printf "PASS\n" ; \
	    else \
		printf "[31mFAIL[39m\n" ; \
	    fi \
	done
	@if [ -s ERRS ] ; \
	 then less ERRS ; \
	 else echo "ALL TESTS PASS" ; rm -f ERRS ; \
	 fi
