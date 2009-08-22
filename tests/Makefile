all: check clean

.SILENT:
.PHONY: check update clean

check:
	for p in *.test; do    \
		echo -n "--> $$p";   \
	  sh $$p > $$p.real;   \
	  diff -u $$p.result $$p.real && echo " OK"; \
	  done

update:
	for p in *.test; do    \
		echo -n "--> $$p";   \
	  sh $$p > $$p.result; \
	  echo " updated";     \
	  done

clean:
	-rm *.real
