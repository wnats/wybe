#  File     : Makefile
#  Author   : Peter Schachte
#  Purpose  : Build and install the Wybe compiler


# Configure these to your preferred installation locations
INSTALLBIN=/usr/local/bin
INSTALLLIB=/usr/local/lib/wybe

# Configure any extra C library and include directories
EXTRALIBS=-L /usr/local/lib -L /opt/homebrew/lib
EXTRAINCLUDES=-I /usr/local/include -I /opt/homebrew/include


# You shouldn't need to edit anything below here
VERSION = 0.2
SRCDIR = src
LIBDIR = wybelibs
WYBELIBS = wybe.o command_line.o logging.o random.o benchmark.o db.o mem.o maybe.o hash.o
CLIBS = wybe/cbits.o
LIBS = $(WYBELIBS) $(CLIBS)
SHELL := /bin/bash


ifeq ($(shell uname), Darwin)
    ISSYSROOT = -isysroot `xcrun --show-sdk-path`
    # On Mac OS X, gtimeout is in homebrew coreutils package
	TIMEOUT = gtimeout
endif

ifeq ($(shell uname), Linux)
    ISSYSROOT =
	TIMEOUT = timeout
endif


all:	wybemk libs

install:	wybemk
	cp wybemk "$(INSTALLBIN)"
	rm -rf "$(INSTALLLIB)"
	mkdir -p "$(INSTALLLIB)"
	cp -r "$(LIBDIR)/." "$(INSTALLLIB)"
	"$(INSTALLBIN)/wybemk" --force-all $(addsuffix ", $(addprefix "$(INSTALLLIB)/,$(WYBELIBS)))


wybemk:	$(SRCDIR)/*.hs $(SRCDIR)/CConfig.hs $(SRCDIR)/Version.lhs
	stack -j3 build && cp "`stack path --local-install-root`/bin/$@" "$@"

libs:	$(addprefix $(LIBDIR)/,$(LIBS))

$(LIBDIR)/%.o:	$(LIBDIR)/%.wybe wybemk
	./wybemk --force-all -L $(LIBDIR) $@

$(LIBDIR)/wybe.o:	wybemk $(LIBDIR)/wybe/*.wybe
	./wybemk --force-all -L $(LIBDIR) $@


$(LIBDIR)/wybe/cbits.o: $(LIBDIR)/wybe/cbits.c
	clang $(ISSYSROOT) $(EXTRAINCLUDES) -c "$<" -o "$@"


$(SRCDIR)/Version.lhs:	$(addprefix $(SRCDIR)/,*.hs)
	@echo -e "Generating Version.lhs for version $(VERSION)"
	@rm -f "$@"
	@printf "Version.lhs automatically generated:  DO NOT EDIT\n" > "$@"
	@printf "\n" >> "$@"
	@printf "> module Version (version,gitHash,buildDate,libDir,defaultTriple) where\n\n" >> "$@"
	@printf "> version :: String\n> version = \"%s\"\n\n" "$(VERSION)" >> "$@"
	@printf "> gitHash :: String\n> gitHash = \"%s\"\n\n" "`git rev-parse --short HEAD`" >> "$@"
	@printf "> buildDate :: String\n> buildDate = \"%s\"\n\n" "`date`" >> "$@"
	@printf "> libDir :: String\n> libDir = \"%s\"\n\n" "$(INSTALLLIB)" >> "$@"
	@printf "> defaultTriple :: String\n> defaultTriple = \"" >> "$@"
	@clang --version | sed -n 's/Target: *\(.*\)/\1\"/p' >> "$@"
	@printf "\n\n" >> "$@"

$(SRCDIR)/CConfig.hs:	$(SRCDIR)/c_config
	$< > $@

$(SRCDIR)/c_config:	$(SRCDIR)/c_config.c
	clang $(ISSYSROOT) $(EXTRAINCLUDES) -o $@ $<


.PHONY:	doc
doc:	src/README.md


# Assemble README markdown source file automatically
src/README.md: src/*.hs Makefile src/README.md.intro src/README.md.outro \
		src/Compiler.png src/Detail.png
	cat src/README.md.intro > "$@"

	printf "The source files in this directory and their purposes are:\n\n" >> "$@"
	printf "| File | Purpose                                      |\n" >> "$@"
	printf "| ---- | -------------------------------------------- |\n" >> "$@"
	for f in src/*.hs ; do \
      b=`basename $$f` ; \
      m=`basename $$f .hs` ; \
	    printf "| `printf '%-20s' [$$b]\(#$$m\)` | " ; \
	    sed -n "s/^-- *Purpose *: *\(.*\)/\1/p" $$f | tr -d '\n' ; \
	    printf " |\n" ; \
	done >> "$@"
	printf "\n\n# Modules in more detail\n\n" >> "$@"

	for f in src/*.hs ; do \
      m=`basename $$f .hs` ; \
	    echo -e ; \
	    echo -e "## $$m <a id="$$m"></a>" ; \
	    sed -E -e '/BEGIN MAJOR DOC/,/END MAJOR DOC/{//d ; s/^-- ? ?//p;}' -e 'd' <$$f ; \
	done >> "$@"

	printf "\n\n" >> "$@"
	cat src/README.md.outro >> "$@"


test:	wybemk
	@rm -f ERRS ; printf "Testing run " > ERRS ; date >> ERRS
	@rm -f $(LIBDIR)/*.o $(LIBDIR)/wybe/*.o
	@echo -e "Building $(LIBDIR)/wybe/cbits.o"
	@make $(LIBDIR)/wybe/cbits.o
	@printf "Testing building wybe library ("
	@$(TIMEOUT) 40 $(MAKE) libs
	@printf ") done.\n"
	@time ( cd test-cases/ && ./run-all-test.sh )

clean:
	stack clean
	rm -f $(SRCDIR)/*.o $(SRCDIR)/*.hi $(SRCDIR)/Version.lhs $(SRCDIR)/CConfig.hs documentation/*.pdf publications/*.pdf $(LIBDIR)/*.o $(LIBDIR)/wybe/*.o test-cases/*.o
