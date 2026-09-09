# Compila o relatório técnico-científico (main.tex -> main.pdf).
# Requer: pdflatex, biber (pacote texlive-bibtex-extra / biber).
#
# Uso:
#   make          -- compilação completa (pdflatex + biber + 2x pdflatex)
#   make clean    -- remove artefatos intermediários (mantém main.pdf)
#   make distclean -- remove também main.pdf

MAIN = main

.PHONY: all clean distclean

all:
	pdflatex -interaction=nonstopmode $(MAIN).tex
	biber $(MAIN)
	pdflatex -interaction=nonstopmode $(MAIN).tex
	pdflatex -interaction=nonstopmode $(MAIN).tex

clean:
	rm -f $(MAIN).aux $(MAIN).bbl $(MAIN).bcf $(MAIN).blg $(MAIN).log \
	      $(MAIN).out $(MAIN).run.xml $(MAIN).toc $(MAIN).lof $(MAIN).lot
	rm -f capitulos/*.aux

distclean: clean
	rm -f $(MAIN).pdf
