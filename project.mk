# Makefile aplikace (adresář project/, viz README). Běží lokálně, v CI i na serveru v releasu
# (deploy volá _prepare, migrations, migrations-kill-sessions a reload-consumers).

ADT_MAKE_SELF := $(dir $(lastword $(MAKEFILE_LIST)))
include $(ADT_MAKE_SELF)common.mk

APP ?= $(SUDO) php bin/console
CODECEPT ?= php vendor/bin/codecept
CODECEPT_RUN ?= $(CODECEPT) run --bootstrap tests/bootstrap.php -vvv --steps
DE_PHP ?= $(SUDO) de php
YARN ?= $(SUDO) yarn

# Composer běží v samostatném jednorázovém kontejneru nad sdíleným image
# appsdevteam/php:${PHP_IMAGE}-composer, ne v PHP-FPM: runtime composer ani git nemá a na serveru
# má kód namountovaný jen pro čtení. Lokálně a v CI přes docker compose (image si stáhne sám),
# na serveru přes `composer` z adt/docker-binaries - deploy uživatel nesmí volat docker compose
# (přes build context by četl libovolný soubor hostu), obálka spustí jen appsdevteam/php
# s PHP_IMAGE z .env pod jeho UID. Mountuje PROJECT_ROOT; na serveru je to domovský adresář
# (i s docker/ a dešifrovaným .env), composeru stačí deploy root project/.
# Název COMPOSER_BIN, ne COMPOSER: makefile proměnné exportuje a COMPOSER composer chápe jako
# cestu ke composer.json.
ifeq ($(strip $(SUDO)),)
COMPOSER_BIN ?= docker compose --project-directory ../docker -f ../docker/docker-compose.yml -f ../docker/docker-compose.$(STAGE).yml -p $(PROJECT_NAME) --profile tools run --rm composer
else
COMPOSER_BIN ?= PROJECT_ROOT=$(PROJECT_ROOT)/project $(SUDO) composer
endif

################################################################################
# Analýza

CS_PATHS ?= app tests
PHPSTAN_PATHS ?= app
PHPSTAN_ARGS ?= -vvv --memory-limit 2G

.PHONY: analyse analyse-cs analyse-cs-fix analyse-sc
analyse: analyse-cs analyse-sc

analyse-cs:
	phpcs -n --standard=ruleset.xml --extensions=php $(CS_PATHS)

analyse-cs-fix:
	phpcbf -n --standard=ruleset.xml --extensions=php $(CS_PATHS)

analyse-sc:
	phpstan analyze $(PHPSTAN_PATHS) $(PHPSTAN_ARGS)

################################################################################
# Sestavení

# Skript package.json pro `make watch` (sandbox: dev = vite dev server)
YARN_WATCH ?= dev

.PHONY: build watch checkout _prepare clear init _install _clear-autoload _clear-opcache _clear-temp
build:
	@if [ "$(STAGE)" = 'local' ]; then \
		$(YARN) build:dev ;\
	else \
		$(YARN) build ;\
	fi

watch:
	$(YARN) $(YARN_WATCH)

checkout: _prepare migrations

# checkout bez migrací - deploy je pouští zvlášť, jednou za stage (app:migrations v receptu adt/docker-deployer).
# Musí to být jeden cíl: `make clear _install build` by kvůli RUN_ARGS (end.mk) spustil jen clear.
_prepare: clear _install build

clear: _clear-opcache _clear-temp _clear-autoload

# Projektové kroky po instalaci (založení a nalití DB apod.): init-after:: v makefilu projektu
init:
	$(MAKE) --no-print-directory _install
	$(MAKE) --no-print-directory build
	$(MAKE) --no-print-directory init-after
.PHONY: init-after
init-after::
	@:

# Composer image ext-* ignoruje, runtime je musí mít podle composer.lock - release s novým
# rozšířením musí spadnout tady, ne až za běhu (bin/check-extensions.php). 0 = vypnuto: deploy
# (recept adt/docker-deployer) kontrolu v _prepare vypíná a volá `make check-extensions` až po
# `dupd up` před přepnutím symlinku - v _prepare ještě běží starý kontejner, nový image s novým
# rozšířením zvedne teprve publish.
CHECK_EXTENSIONS ?= 1
.PHONY: check-extensions
check-extensions:
	$(SUDO) php $(ADT_MAKE_SELF)bin/check-extensions.php

_install:
	@if [ "$(STAGE)" = "local" ] || [ "$(STAGE)" = "ci" ]; then \
		$(COMPOSER_BIN) install ;\
	else \
		$(COMPOSER_BIN) install --no-dev ;\
	fi
	@[ "$(CHECK_EXTENSIONS)" != 1 ] || $(SUDO) php $(ADT_MAKE_SELF)bin/check-extensions.php
	$(YARN) install

_clear-autoload:
	$(COMPOSER_BIN) dump-autoload

# Opcache se pri kazdem deployi resetuje kvuli pameti. Pri opcache.validate_timestamps=0 se
# skripty starych releasu (kazdy ma diky $realpath_root v nginx vlastni klice) nikdy
# nezneplatni a z pameti nezmizi - po par deployich bez restartu FPM je opcache plna a novy
# release uz se necachuje. Proto deploy bez uspesneho resetu spadne.
#
# PHP-FPM je pri deployi obcas zrovna vytizene nebo se restartuje a FastCGI spojeni
# spadne na "Stream got blocked, or terminated" - proto par pokusu s pauzou.
OPCACHE_RESET_ATTEMPTS ?= 5
_clear-opcache:
	@for i in $$(seq 1 $(OPCACHE_RESET_ATTEMPTS)); do \
		$(DE_PHP) cachetool opcache:reset && exit 0; \
		echo "opcache:reset selhal (pokus $$i/$(OPCACHE_RESET_ATTEMPTS))" >&2; \
		[ $$i -lt $(OPCACHE_RESET_ATTEMPTS) ] && sleep $$((i * 2)); \
	done; \
	exit 1

_clear-temp:
	$(DE_PHP) rm -rf temp/*

################################################################################
# Migrace a consumery
#
# Deploy (recept adt/docker-deployer) od cílů čeká:
# - `make migrations MIGRATIONS_DRY_RUN=1` vypíše plán a u čekajících migrací řádek `MIGRATIONS_PENDING`
# - `make migrations MIGRATIONS_AUTO_CONFIRM=1` migrace provede bez dotazu
# - `make migrations-kill-sessions` (volitelný) a `make reload-consumers`
# Lokálně `make migrations` migruje rovnou (argumenty za `--` jdou do migrations:migrate).
#
# Víc databází (multi-tenancy): PROJECTS = názvy projektů, kroky se pak opakují pro každý
# s APP_ENV=project/<název>. Prázdné = jedna DB bez APP_ENV.
# Projektové kroky (příkazy shellu, běží s APP_ENV daného projektu):
# - MIGRATIONS_LOCAL_BEFORE / MIGRATIONS_LOCAL_AFTER - lokálně před a po migracích (založení DB, data)
# - MIGRATIONS_AFTER - po migracích na všech stagích, ne v dry-runu
# Kroky jednou za celé migrace: migrations-before:: a migrations-after:: v makefilu projektu
# (MIGRATIONS_DRY_RUN si hlídají samy).

# Projekt bez DB (žádný adresář migrations/) má migrace prázdné
MIGRATIONS_ENABLED ?= $(if $(wildcard migrations),1)
PROJECTS ?=
MIGRATIONS_COMMAND ?= migrations
MIGRATIONS = $(APP) $(MIGRATIONS_COMMAND):migrate --no-interaction --allow-no-migration -vv
MIGRATIONS_FILE = /tmp/migrations-$(PROJECT_NAME)-$(MIGRATIONS_COMMAND)
MIGRATIONS_LABEL ?= $(APP_ENV)

# Pro každý projekt z PROJECTS (nebo jednou bez APP_ENV) v subshellu s APP_ENV=project/<p> pustí $(2),
# před ním vypíše "== $(1): <p> ==". Proměnná pro make v podřízeném volání: $$APP_ENV_ARG.
# První chyba ukončí celý cíl. Subshell nesmí být v `( ... ) || exit`: v seznamu s || bash set -e
# uvnitř ignoruje a chyba migrace by prošla - výsledek se proto kontroluje až po něm.
# PROJECTS z .env může mít uvozovky (PROJECTS="a b" kvůli `source .env`) - pryč s nimi.
define for_each_project
	@for p in $(or $(subst ",,$(PROJECTS)),.); do ( \
		set -e; APP_ENV_ARG=; \
		if [ "$$p" != . ]; then export APP_ENV=project/$$p; APP_ENV_ARG="APP_ENV=project/$$p"; echo "== $(1): $$p =="; fi; \
		$(2) \
	); rc=$$?; [ $$rc = 0 ] || exit $$rc; done
endef

.PHONY: migrations migrations-before migrations-after migrations-diff reload-consumers _migrations-run _migrations-deploy
migrations:
ifeq ($(MIGRATIONS_ENABLED),1)
	@$(MAKE) --no-print-directory migrations-before
	$(call for_each_project,migrations,\
		if [ "$(STAGE)" = local ] && [ "$(MIGRATIONS_DRY_RUN)" != 1 ]; then \
			$(if $(MIGRATIONS_LOCAL_BEFORE),$(MIGRATIONS_LOCAL_BEFORE);) \
			$(MIGRATIONS) $(RUN_ARGS); \
			$(if $(MIGRATIONS_LOCAL_AFTER),$(MIGRATIONS_LOCAL_AFTER);) \
		else \
			$(SUBMAKE) _migrations-deploy $$APP_ENV_ARG MIGRATIONS_LABEL=$$p; \
		fi; \
		$(if $(MIGRATIONS_AFTER),[ "$(MIGRATIONS_DRY_RUN)" = 1 ] || { $(MIGRATIONS_AFTER); };))
	@$(MAKE) --no-print-directory migrations-after
else
	@:
endif

migrations-before::
	@:

migrations-after::
	@:

# Migrace bez plánu a ptaní
_migrations-run:
	$(MIGRATIONS)

# Migrace s plánem (dry-run). Prázdná DB (nový projekt) jde bez dry-runu: migrace, které v preUp()/up()
# čtou z DB, by v něm spadly na tabulkách, které vytváří předchozí migrace - dry-run je neprovede.
# Na prázdné DB navíc není co kontrolovat. Pád dry-runu (chyba aplikace) není čekající migrace,
# deploy musí skončit. V CI se migruje bez ptaní.
_migrations-deploy:
	@set -e ;\
	if $(APP) $(MIGRATIONS_COMMAND):current | grep -q "No migration executed yet"; then \
		if [ "$(MIGRATIONS_DRY_RUN)" = 1 ]; then echo "MIGRATIONS_PENDING: $(MIGRATIONS_LABEL) - prázdná databáze, poběží všechny migrace bez dry-runu"; exit 0; fi ;\
		if [ "$(MIGRATIONS_AUTO_CONFIRM)" != 1 ] && [ "$(STAGE)" != ci ]; then \
			echo -n "Databáze $(MIGRATIONS_LABEL) je prázdná - spustit všechny migrace bez dry-runu? [y/N] " && read ans ;\
			[ "$${ans:-N}" = y ] || exit 1 ;\
		fi ;\
		$(MIGRATIONS) ;\
	else \
		if ! $(MIGRATIONS) --dry-run > $(MIGRATIONS_FILE) 2>&1; then \
			cat $(MIGRATIONS_FILE); rm -f $(MIGRATIONS_FILE) ;\
			echo "ERROR: dry-run migraci $(MIGRATIONS_LABEL) selhal (pad aplikace, ne cekajici migrace)" >&2; exit 1 ;\
		fi ;\
		cat $(MIGRATIONS_FILE) ;\
		if ! grep -q "Already at the latest version" $(MIGRATIONS_FILE); then \
			if [ "$(MIGRATIONS_DRY_RUN)" = 1 ]; then echo "MIGRATIONS_PENDING: $(MIGRATIONS_LABEL)" ;\
			elif [ "$(MIGRATIONS_AUTO_CONFIRM)" = 1 ] || [ "$(STAGE)" = ci ]; then $(MIGRATIONS) ;\
			else \
				echo -n "Are the migrations ok? [y/N] " && read ans ;\
				if [ "$${ans:-N}" = y ]; then $(MIGRATIONS); else rm -f $(MIGRATIONS_FILE); exit 1; fi ;\
			fi ;\
		fi ;\
		rm -f $(MIGRATIONS_FILE) ;\
	fi

# Argumenty migrations:diff navíc, např. --filter-expression pro tabulky mimo entity projektu
MIGRATIONS_DIFF_ARGS ?=
migrations-diff:
	$(APP) migrations:diff --allow-empty-diff $(MIGRATIONS_DIFF_ARGS)

# Deploy ho volá v údržbě těsně před migracemi: až MIGRATIONS_KILL_WAIT sekund počká, než consumery
# dodělají rozpracovaný job, a pak zabije ostatní spojení DB uživatele (dbal:kill-sessions
# z adt/doctrine-components), aby DDL na Galeře nenarazilo na zámky běžící aplikace.
# Zapíná ho MIGRATIONS_KILL_SESSIONS = 1 - bez cíle ho recept přeskočí.
ifeq ($(MIGRATIONS_KILL_SESSIONS),1)
MIGRATIONS_KILL_WAIT ?= 60
.PHONY: migrations-kill-sessions
migrations-kill-sessions:
	$(call for_each_project,zabití spojení,$(APP) dbal:kill-sessions --wait=$(MIGRATIONS_KILL_WAIT);)
endif

# Deploy ho volá po publikaci (app:reload_consumers v receptu) a na začátku údržby před migracemi:
# consumery drží v paměti kód předchozího releasu - řízeně se ukončí a supervisor je pustí znovu
# nad novým `current`. Příkaz (pro každý projekt) dává RELOAD_CONSUMERS, např.
# $(APP) background-queue:reload-consumers $(CONSUMERS); prázdné = projekt bez consumerů.
RELOAD_CONSUMERS ?=
reload-consumers:
ifneq ($(strip $(RELOAD_CONSUMERS)),)
	$(call for_each_project,consumery,$(RELOAD_CONSUMERS);)
else
	@:
endif

################################################################################
# Testy (Codeception)

# Suity = tests/<Suite>.suite.yml
TEST_SUITES ?= $(sort $(basename $(basename $(notdir $(wildcard tests/*.suite.yml)))))

# Všechny suity paralelně: výstup každé do tests/_output/<suite>.log, na konci souhrn a chyby
# spadlých suit. Paralelní suity nesmí sdílet data (např. jednu testovací DB, kterou si
# navzájem přepíšou). Projekt proto může suitě přidat proměnné prostředí
# (TEST_ENV_<Suite> = VAR=hodnota ..., do PHP kontejneru přes `de`) a příkaz, který se spustí
# před ní (TEST_BEFORE_<Suite> = "<příkaz> &&"), např. založení vlastní DB.
#
# Suita s TEST_SHARDS_<Suite> = N běží rozdělená na N souběžných částí (po celých Cestech,
# bin/test-shard-files; log tests/_output/<Suite>-<i>.log). Každá část má env TEST_SHARD=i - podle něj si projekt
# oddělí data (např. vlastní DB) - a vlastní Playwright server (playwright_1 … v docker-compose.local.yml):
# server drží jediný prohlížeč, souběžné běhy by si ho přebíraly.
# TEST_ENV_<Suite> a TEST_BEFORE_<Suite> dostanou v $(1) číslo části (bez rozdělení prázdné).
test_jobs = $(foreach s,$(TEST_SUITES),$(if $(filter-out 1,$(or $(TEST_SHARDS_$(s)),1)),$(foreach i,$(shell seq 1 $(TEST_SHARDS_$(s))),$(s)-$(i)),$(s)))
test_job_suite = $(word 1,$(subst -, ,$(1)))
test_job_shard = $(word 2,$(subst -, ,$(1)))
test_job_env = $(strip $(call TEST_ENV_$(call test_job_suite,$(1)),$(call test_job_shard,$(1))) $(if $(call test_job_shard,$(1)),TEST_SHARD=$(call test_job_shard,$(1))))
test_job_cmd = echo "[$(1)] běží, výstup v tests/_output/$(1).log"; bash -c '$(call TEST_BEFORE_$(call test_job_suite,$(1)),$(call test_job_shard,$(1))) $(SUBMAKE) test-suite SUITE=$(call test_job_suite,$(1)) TEST_OUTPUT=$(1) $(if $(call test_job_shard,$(1)),SHARD=$(call test_job_shard,$(1))/$(TEST_SHARDS_$(call test_job_suite,$(1)))) TEST_ENV="$(call test_job_env,$(1))"' > tests/_output/$(1).log 2>&1 & pids+=($$!);

.PHONY: test test-suite test-unit test-acceptance test-acceptance-retry test-crawler test-coverage test-prepare
test:
	@mkdir -p tests/_output; pids=(); start=$$SECONDS; \
	$(foreach job,$(test_jobs),$(call test_job_cmd,$(job))) \
	jobs=($(test_jobs)); failed=(); \
	for i in "$${!jobs[@]}"; do \
		if wait $${pids[$$i]}; then \
			printf '\033[32m[%s] OK\033[0m\n' $${jobs[$$i]}; \
		else \
			failed+=($${jobs[$$i]}); \
			printf '\033[31m[%s] SELHALO\033[0m\n' $${jobs[$$i]}; \
		fi; \
	done; \
	echo "Celkem $$((SECONDS - start)) s"; \
	for job in $${failed[@]+"$${failed[@]}"}; do \
		printf '\n\033[31m===== %s =====\033[0m\n' $$job; \
		sed -n '/There w[ae][rs]/,$$p' tests/_output/$$job.log | grep . || tail -n 40 tests/_output/$$job.log; \
	done; \
	[ $${#failed[@]} -eq 0 ]

# Jedna suita (nebo její část: SHARD=i/N) s vlastní výstupní složkou - paralelní běhy by si
# jinak přepisovaly screenshoty a seznam spadlých testů (tests/_output/failed). Část i jede
# přes vlastní Playwright server playwright_<i> (hlavní playwright zůstává samostatným během).
test_shard_index = $(firstword $(subst /, ,$(SHARD)))
# Část suity = skupina ze souboru se seznamem jejích Cestů (bin/test-shard-files dělí po celých
# souborech, codecept --shard by rozdělil i testy jednoho Cestu, které na sobě závisí)
test_shard_file = tests/_output/shards/$(1)-$(subst /,-of-,$(SHARD))
test_shard_args = $(if $(SHARD),-g shard -o "groups: shard: $(call test_shard_file,$(1))")
test_shard_prepare = $(if $(SHARD),mkdir -p tests/_output/shards && $(ADT_MAKE_SELF)bin/test-shard-files $(1) $(subst /, ,$(SHARD)) > $(call test_shard_file,$(1)) &&)
test-suite:
	@mkdir -p tests/_output/$(or $(TEST_OUTPUT),$(SUITE))
	$(call test_shard_prepare,$(SUITE)) $(if $(TEST_ENV),$(TEST_ENV) envs="$$(printf '%s\n' $(TEST_ENV))") $(CODECEPT_RUN) -o "paths: output: tests/_output/$(or $(TEST_OUTPUT),$(SUITE))" $(call test_shard_args,$(SUITE)) $(if $(SHARD),-o "modules: config: Playwright: pw_server: http://playwright_$(test_shard_index):8191") $(SUITE)

# Testovací DB z TEST_DB_NAME (make test-unit TEST_DB_NAME=...) jde do PHP kontejneru
test-unit:
	$(if $(TEST_DB_NAME),TEST_DB_NAME=$(TEST_DB_NAME) envs="TEST_DB_NAME=$(TEST_DB_NAME)") $(CODECEPT_RUN) Unit

# SHARD=i/N spustí jen i-tou z N částí (CI: job s parallel)
test-acceptance:
	$(call test_shard_prepare,Acceptance) $(CODECEPT_RUN) $(call test_shard_args,Acceptance) Acceptance

# Zopakuje jen testy spadlé v předchozím běhu (skupina "failed" z RunFailed extension) - mitigace flaky browser testů v CI
test-acceptance-retry:
	$(CODECEPT_RUN) -g failed

test-crawler:
	$(CODECEPT_RUN) Crawler

test-coverage:
	APP_TEST=1 $(APP) adt:component-test-coverage

test-prepare:
	$(CODECEPT) build

################################################################################
# Bezpečnost a CRA

# Audit zranitelností závislostí (composer.lock + yarn.lock).
# --locked: audituje composer.lock, funguje i bez nainstalovaného vendoru.
#
# `yarn npm audit` se dotazuje registry po síti a v CI to občas spadne na socket timeout.
# Yarn vrací exit 1 jak pro síťovou chybu, tak pro nalezené advisories, proto se rozhoduje
# podle výstupu: opakuje se pouze síťová chyba, nález advisories skončí hned prvním pokusem.
# Výstup jde do souboru a vypisuje se až po doběhnutí - pipe do tee by exit kód přepsal tee-em.
AUDIT_NETWORK_ERRORS = RequestError|Timeout awaiting|ETIMEDOUT|ECONNRESET|ECONNREFUSED|ENOTFOUND|EAI_AGAIN|socket hang up
.PHONY: audit sbom sbom-check
# --abandoned=report: opuštěné balíčky jen vypíše (Composer 2.6+ na ně jinak vrací chybu), audit má
# hlídat zranitelnosti; náhrada opuštěného balíčku je práce pro vývoj, ne důvod blokovat pipeline
audit:
	$(COMPOSER_BIN) audit --locked --abandoned=report
	@out=$$(mktemp); \
	for i in 1 2 3; do \
		if $(YARN) npm audit --all --severity info > $$out 2>&1; then \
			cat $$out; rm -f $$out; exit 0; \
		fi; \
		cat $$out; \
		if ! grep -qE '$(AUDIT_NETWORK_ERRORS)' $$out; then \
			rm -f $$out; exit 1; \
		fi; \
		echo "yarn npm audit: síťová chyba, pokus $$i/3 selhal"; \
		[ $$i -lt 3 ] && { echo "Zkouším znovu za 15 s..."; sleep 15; }; \
	done; \
	rm -f $$out; \
	echo "yarn npm audit: registry nedostupný po 3 pokusech, audit neproveden."; \
	exit 1

# SBOM (Software Bill of Materials) - CycloneDX, jen pro projekty pod CRA. Commitnutý adresář
# sbom/ je zároveň přepínač: když existuje, `make release` SBOM přegeneruje a CI ho na tagu
# kontroluje a audit v CI blokuje.
# Výstup je reprodukovatelný (bez timestampů a náhodných UUID):
#   - COMPOSER_ROOT_VERSION: root verze nezávislá na stavu gitu (CI má detached HEAD)
#   - pinovaná verze yarn pluginu (dlx jinak stahuje vždy nejnovější)
#   - bin/sbom-normalize.php odstraní zbylá volatilní metadata (verze nástrojů, HEAD sha, URL)
#
# bin/sbom-check-vendor.php hlídá, že vendor odpovídá composer.lock. Plugin čte nainstalované
# balíčky, ne lockfile, takže při driftu (git pull nebo přepnutí větve bez composer install)
# by se SBOM tiše vygeneroval se starými verzemi a spadlo by to až na sbom-check v CI.
sbom:
	@grep -q '"cyclonedx/cyclonedx-php-composer"' composer.json || { \
		echo "Chybí CycloneDX plugin. Zapnutí CRA viz README projektu, sekce Bezpečnost a CRA."; exit 1; }
	$(SUDO) php $(ADT_MAKE_SELF)bin/sbom-check-vendor.php
	@mkdir -p sbom
	COMPOSER_ROOT_VERSION=dev-main $(COMPOSER_BIN) CycloneDX:make-sbom --output-format=JSON --output-file=sbom/composer.cdx.json --omit=dev --output-reproducible
	$(YARN) dlx -q @cyclonedx/yarn-plugin-cyclonedx@3.3.2 --output-format JSON --output-file sbom/yarn.cdx.json --prod --output-reproducible
	$(SUDO) php $(ADT_MAKE_SELF)bin/sbom-normalize.php sbom/composer.cdx.json sbom/yarn.cdx.json
	@echo "SBOM: project/sbom/composer.cdx.json + project/sbom/yarn.cdx.json"

# Ověří, že commitnutý SBOM odpovídá aktuálním lockfilům
sbom-check: sbom
	@if [ -n "$$(git status --porcelain sbom/)" ]; then \
		git status --porcelain sbom/; \
		git --no-pager diff sbom/; \
		echo "SBOM neodpovídá lockfilům - spusť 'make sbom' a commitni adresář project/sbom/"; \
		exit 1; \
	fi

include $(ADT_MAKE_SELF)end.mk
