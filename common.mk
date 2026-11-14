# Společný začátek kořenového, projektového i dockerového makefilu. Načítá ho root.mk, project.mk
# a docker.mk, samostatně se nepoužívá.

SHELL = /bin/bash

# Argumenty za "--" (make deploy -- main), viz https://stackoverflow.com/a/14061796/4837606.
# end.mk z nich udělá prázdné cíle, aby je make nespustil jako další cíle.
RUN_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))

# Podřízený make v řádku receptu, který dělá i něco jiného. $(MAKE) přímo v takovém řádku by make
# spustil i s -n (make -n migrations by migroval, make -n _env přepsal .env) - odkaz přes proměnnou ne.
SUBMAKE = $(MAKE) --no-print-directory

.DEFAULT_GOAL := help

# Seznam cílů (bez pomocných _cílů) ze všech načtených makefilů
.PHONY: help
help:
	@grep -hE '^[a-z][a-zA-Z0-9_-]*:([^=]|$$)' $(MAKEFILE_LIST) | cut -d: -f1 | sort -u | tr '\n' ' '; echo
