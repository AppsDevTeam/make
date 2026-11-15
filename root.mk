# Kořenový makefile projektu (viz README). Konfigurace (.env z config/), secrets (SOPS), release
# a přeposílání cílů do project/ a docker/. Deploy je v adt/docker-deployer (make/deploy.mk).

ADT_MAKE_SELF := $(dir $(lastword $(MAKEFILE_LIST)))
include $(ADT_MAKE_SELF)common.mk

SOPS ?= $(SUDO) sops

# Cíle, které jen přeposílá do project/ a docker/. Projekt přidá svoje přes PROJECT_MAKE_TARGETS
# a DOCKER_MAKE_TARGETS (definované před include).
ADT_PROJECT_TARGETS = analyse analyse-cs analyse-cs-fix analyse-sc audit build checkout clear init \
	migrations migrations-diff reload-consumers sbom sbom-check test test-acceptance test-acceptance-retry \
	test-coverage test-crawler test-prepare test-suite test-unit watch
ADT_DOCKER_TARGETS = audit-image docker-down docker-up docker-upd docker-upd-no-pull _docker-upd-no-build

.PHONY: $(ADT_PROJECT_TARGETS) $(PROJECT_MAKE_TARGETS) $(ADT_DOCKER_TARGETS) $(DOCKER_MAKE_TARGETS)
HELP_TARGETS += $(ADT_PROJECT_TARGETS) $(PROJECT_MAKE_TARGETS) $(ADT_DOCKER_TARGETS) $(DOCKER_MAKE_TARGETS)
$(sort $(ADT_PROJECT_TARGETS) $(PROJECT_MAKE_TARGETS)):
	@$(MAKE) --no-print-directory -C project $@

$(sort $(ADT_DOCKER_TARGETS) $(DOCKER_MAKE_TARGETS)):
	@$(MAKE) --no-print-directory -C docker $@

################################################################################
# Konfigurace

# Remote šablony projektu (sandbox), `make config` ho přidá. Prázdné = nepřidávat.
SANDBOX_REMOTE ?= ssh://git@git.appsdevteam.com:2222/adt/sandbox_web.git

.PHONY: config
config:
	@$(MAKE) --no-print-directory _env STAGE=local

	@touch .env

	@# I kořenový .env (od 1.0 ho píše _env): CI ho po `make config` načte do prostředí
	@# (`source .env`) a proměnná ze shellu v docker compose přebije docker/.env - prázdné
	@# PROJECT_ROOT z config/.env.local pak rozbilo mount (invalid spec: :/var/www/html).
	@for file in .env docker/.env project/.env; do \
		sed -i.bak "/^PROJECT_ROOT=/s?PROJECT_ROOT=.*?PROJECT_ROOT=$$(pwd)/project?" $$file && rm $$file.bak; \
		sed -i.bak "/^DOCKER_SELENIUM=/s#DOCKER_SELENIUM=.*#DOCKER_SELENIUM=$$([ "$$(uname -p)" = "arm" ] && echo "seleniarm/standalone-chromium" || echo "selenium/standalone-chrome")#" $$file && rm $$file.bak; \
		sed -i.bak "/^DOCKER_VOLUME_FLAG=/s/DOCKER_VOLUME_FLAG=.*/DOCKER_VOLUME_FLAG=`if [ "\`uname\`" = "Linux" ]; then echo ':consistent'; else echo ':delegated'; fi`/" $$file && rm $$file.bak; \
		sed -i.bak "/^APP_EDITOR=/s#APP_EDITOR=.*#APP_EDITOR=$$([ "$$(uname)" = "Darwin" ] && echo "phpstorm://open?file=%file\&line=%line" || echo "editor://%action/?file=%file\&line=%line\&search=%search\&replace=%replace")#" $$file && rm $$file.bak; \
		sed -i.bak "/^USER_EMAIL=/s/USER_EMAIL=.*/USER_EMAIL=`git config user.email`/" $$file && rm $$file.bak; \
	done

	@command -v git > /dev/null && git config core.hooksPath hooks || true
	@[ -z "$(SANDBOX_REMOTE)" ] || git remote get-url sandbox >/dev/null 2>&1 || git remote add sandbox $(SANDBOX_REMOTE)

# Druhá izolovaná instance projektu (např. pro Claude Code): make config && make config-claude N=1
# CONFIG_CLAUDE_DOMAIN: lokální doména projektu, druhá instance dostane <doména>_cl<N>.<tld>
# (www.sandbox.loc → www.sandbox_cl1.loc); prázdné = doména se nemění
CONFIG_CLAUDE_DOMAIN ?=
.PHONY: config-claude
config-claude:
	@if [ -z "$(N)" ]; then \
		echo "Chybí číslo instance. Použití: make config-claude N=<číslo>"; \
		exit 1; \
	fi
	@# <projekt>-local → <projekt>_cl<N>-local (opakované spuštění jen změní číslo)
	perl -pi -e 's/^PROJECT_NAME=(.+?)(?:_cl\d+)?-local$$/PROJECT_NAME=$$1_cl$(N)-local/' docker/.env project/.env
	$(if $(CONFIG_CLAUDE_DOMAIN),perl -pi -e 's/\Q$(CONFIG_CLAUDE_DOMAIN)\E/$(basename $(CONFIG_CLAUDE_DOMAIN))_cl$(N)$(suffix $(CONFIG_CLAUDE_DOMAIN))/g' docker/.env project/.env)
	@# Druhá instance nepublikuje žádný port (kolize s PROJECT_IP hlavní instance): všechny porty
	@# v docker-compose.local.yml (gitignorovaná pracovní kopie) jsou na PROJECT_IP. `!reset []`
	@# i u služeb, které by jinak porty zdědily z ci-local.yml.
	perl -0pi -e 's/^    ports:(?: !override)?\n(?:      - "\$$\{PROJECT_IP[^\n]*\n)+/    ports: !reset []\n/mg' docker/docker-compose.local.yml
	@# ani se nehlásí sdílené proxy - Traefik by doménu projektu routoval do obou instancí
	perl -ni -e 'print unless /^LOCAL_PROXY=/' docker/.env
	echo 'LOCAL_PROXY=0' >> docker/.env

# Pracovní kopie z šablon v config/ pro STAGE: soubory stage do docker/ a project/, .env v kořeni,
# docker/ a project/ (vrstvy config/.env.common, config/<dir>/.env.common, config/.env.<stage>,
# config/<dir>/.env.<stage>, zašifrované se rozšifrují). Deploy ho pouští v dočasném klonu na serveru.
# Projektové kroky navíc: _env-after:: v makefilu projektu.
.PHONY: _env _env-after
_env:
	@# PHP načítá všechna ini v conf.d - ini předchozí stage (po `make config STAGE=...`) pryč
	@rm -f docker/php/usr/local/etc/php/conf.d/default.*.ini
	@for dir in docker project; do \
		find config/$$dir -type f \( -name "*$(STAGE)*" \) ! -name ".env*" | while read src; do \
			dest="$$dir/$${src#config/$$dir/}"; \
			mkdir -p "$$(dirname "$$dest")"; \
			cp -f "$$src" "$$dest"; \
		done; \
	done

	@# Skládá se do dočasného souboru - když SOPS neumí některou vrstvu rozšifrovat,
	@# zůstane stávající .env nedotčený místo aby se useknul na půlce
	@set -e; tmp=".env.tmp"; \
	cat config/.env.common > $$tmp; \
	printf '\n\n' >> $$tmp && $(SUBMAKE) _sops-cat FILE=config/.env.$(STAGE) >> $$tmp; \
	mv -f $$tmp .env

	@set -e; for dir in docker project; do \
		tmp="$$dir/.env.tmp"; \
		cat config/.env.common > $$tmp; \
		printf '\n\n' >> $$tmp && cat config/$$dir/.env.common >> $$tmp; \
		printf '\n\n' >> $$tmp && $(SUBMAKE) _sops-cat FILE=config/.env.$(STAGE) >> $$tmp; \
		printf '\n\n' >> $$tmp && $(SUBMAKE) _sops-cat FILE=config/$$dir/.env.$(STAGE) >> $$tmp; \
		mv -f $$tmp $$dir/.env; \
	done

	@# Zašifrované JSON soubory v config/project (SOPS) - rozšifrují se do pracovní
	@# kopie vedle ostatních configů. Kdo klíč rozšifrovat neumí (není mezi příjemci
	@# v .sops.yaml), nechá si stávající soubor, make kvůli tomu nespadne.
	@for src in $$(find config/project -type f -name "*.json"); do \
		grep -q '"sops"' "$$src" 2>/dev/null || continue; \
		dest="project/$${src#config/project/}"; \
		if $(SOPS) decrypt "$$src" > "$$dest.tmp" 2>/dev/null; then \
			mv -f "$$dest.tmp" "$$dest"; \
		else \
			rm -f "$$dest.tmp"; \
			echo "Nepodarilo se rozsifrovat $$src (tvuj SSH klic neni v .sops.yaml?) - ponechavam $$dest" >&2; \
		fi; \
	done

	@for file in .env docker/.env project/.env; do \
		sed -i.bak "/^USER=/s/USER=.*/USER=`id -u`:`id -g`/" $$file && rm $$file.bak; \
	done
	@$(MAKE) --no-print-directory _env-after

_env-after::
	@:

################################################################################
# Secrets (SOPS + age, příjemci v .sops.yaml)

# Stage, jejíž .env soubory šifrují/dešifrují secrets targety (default = aktuální STAGE).
# `all` (nebo nenastavená STAGE, např. v čerstvém checkoutu před `make config`) = všechny stage;
# to se hodí při rotaci klíčů v .sops.yaml, kdy je potřeba přešifrovat úplně všechno.
SECRETS_STAGE ?= $(STAGE)
SOPS_STAGE_GLOB = $(if $(filter-out all,$(SECRETS_STAGE)),.env.$(SECRETS_STAGE),.env.*)
# Soubory jedné stage - pro secrets-decrypt/secrets-encrypt.
# .env.common je sdílený nešifrovaný základ, do šifrování nepatří.
SOPS_FILES = $(shell find ./config -type f -name "*$(SOPS_STAGE_GLOB)" ! -name "*.env.common")
# Kontrola v pre-commit hooku (_secrets-check) - default všechny stage. Projekt, který šifruje
# jen některé (hesla dockerové DB local a ci v plaintextu), ho zúží.
SOPS_CHECK_FILES ?= $(shell find ./config -type f -name "*.env.*" ! -name "*.env.common")
# `export` v makefilu projektu by find pouštěl u každého řádku každého receptu
unexport SOPS_FILES SOPS_CHECK_FILES

# Použití: make secrets-decrypt [SECRETS_STAGE=<stage>|all] - bez parametru aktuální STAGE.
# Deploy předává stage explicitně, aby ho nerozbil poškozený soubor cizí stage.
.PHONY: secrets-decrypt secrets-encrypt _secrets-stage-check _secrets-check _sops-cat
secrets-decrypt: _secrets-stage-check
	@for file in $(SOPS_FILES); do \
		if grep -q "sops_mac" "$$file" 2>/dev/null; then \
			echo "Decrypting $$file"; \
			$(SOPS) decrypt --input-type dotenv --output-type dotenv -i "$$file"; \
		fi; \
	done

# Použití: make secrets-encrypt [SECRETS_STAGE=<stage>|all] - bez parametru aktuální STAGE
secrets-encrypt: _secrets-stage-check
	@# Šifruje se kopie - originál se přepíše, až když SOPS projde a ve výsledku jsou ENC[...] hodnoty.
	@# --filename-override je nutný, aby se creation_rules v .sops.yaml vyhodnotily podle skutečné
	@# cesty, ne podle jména dočasného souboru (jinak může soubor dostat jiné příjemce).
	@for file in $(SOPS_FILES); do \
		if ! grep -q "sops_mac" "$$file" 2>/dev/null; then \
			cp "$$file" "$$file.sops-tmp"; \
			if $(SOPS) encrypt --input-type dotenv --output-type dotenv --filename-override "$$file" -i "$$file.sops-tmp" \
				&& grep -v "^sops_" "$$file.sops-tmp" | grep -q "ENC\[" 2>/dev/null; then \
				mv "$$file.sops-tmp" "$$file"; \
				echo "Encrypted $$file"; \
			else \
				rm -f "$$file.sops-tmp"; \
			fi; \
		fi; \
	done

# Neexistující stage nesmí projít tiše - glob by nematchnul nic a target by skončil
# s exit 0, takže by se `make secrets-encrypt SECRETS_STAGE=<překlep>` tvářil jako úspěch
# a nechal na disku nezašifrovaná hesla
_secrets-stage-check:
	@if [ -n "$(filter-out all,$(SECRETS_STAGE))" ] && [ ! -f "config/.env.$(SECRETS_STAGE)" ]; then \
		echo "Neznámá stage '$(SECRETS_STAGE)' - config/.env.$(SECRETS_STAGE) neexistuje."; \
		echo "Dostupné: $(patsubst ./config/.env.%,%,$(wildcard ./config/.env.*)) all" | sed 's/ common//'; \
		exit 1; \
	fi

# Kontrola v pre-commit hooku - projíždí SOPS_CHECK_FILES bez ohledu na SECRETS_STAGE.
# Vzor citlivých jmen musí sedět s encrypted_regex v .sops.yaml, jinak se obě strany
# rozejdou: buď hook pustí do gitu plaintext, který SOPS nešifruje, nebo naopak
# spadne na proměnné, kterou zašifrovat neumí.
# Hlídá se hodnota, ne jen název: `API_KEY=` bez hodnoty je placeholder, `API_KEY=abc`
# je secret, který do gitu nepatří.
SECRETS_PATTERN ?= ^[A-Za-z0-9_]*(PASSWORD|SECRET|TOKEN|KEY|PRIVATE)[A-Za-z0-9_]*=..*
_secrets-check:
	@for file in $(SOPS_CHECK_FILES); do \
		if ! grep -q "sops_mac" "$$file" 2>/dev/null && grep -qE "$(SECRETS_PATTERN)" "$$file" 2>/dev/null; then \
			echo "WARNING: $$file contains unencrypted sensitive data"; \
			exit 1; \
		fi; \
	done

_sops-cat:
	@if [ -f "$(FILE)" ]; then \
		if grep -q "sops_mac" "$(FILE)" 2>/dev/null; then \
			decrypted=$$($(SOPS) decrypt --input-type dotenv --output-type dotenv "$(FILE)") \
				|| { echo "Nepodarilo se rozsifrovat $(FILE). Je tvuj SSH klic mezi prijemci v .sops.yaml? Pokud ne, musi te tam nekdo s pristupem pridat a soubory presifrovat (make secrets-decrypt && make secrets-encrypt)." >&2; exit 1; }; \
			printf '%s\n' "$$decrypted" | grep -v "^sops_" || true; \
		else \
			cat "$(FILE)"; \
		fi; \
	fi

################################################################################
# Release

# Verze vRRRR.M.N (rok, měsíc od 1, pořadí releasu v měsíci od 1), release notes dopíše Claude
# (skill /release-notes projektu), u projektu pod CRA (existuje project/sbom/) přegeneruje SBOM
# a po odsouhlasení commitne, otaguje a pushne. Deploy zůstává samostatný krok.
#
# Remote se bere z upstreamu aktuální větve: v odvozeném projektu je to origin, v repu samotného
# sandboxu sandbox (origin tam není, jen by duplikoval stejnou URL).
#
# USER=$(id -un) u claude: `.env` obsahuje USER=<uid> pro Docker a `export` v makefilu projektu
# ho protlačí do všech podprocesů. Claude pak hledá přihlášení pod účtem "501" a hlásí "Not logged in".
# Přihlašovací jméno mu proto vrátíme jen pro tenhle příkaz.
RELEASE_NOTES ?= docs/release-notes.md
.PHONY: release
release:
	@command -v claude >/dev/null || { echo "claude CLI není nainstalované"; exit 1; }
	@git diff --quiet && git diff --cached --quiet || { echo "Working tree není čistý - commitni nebo stashni změny."; exit 1; }
	@set -e; \
	REMOTE=$$(git config "branch.$$(git branch --show-current).remote" || true); \
	[ -n "$$REMOTE" ] || { echo "Aktuální větev nesleduje žádný remote (git branch --set-upstream-to=...)."; exit 1; }; \
	git fetch --tags $$REMOTE; \
	LAST_TAG=$$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true); \
	PREFIX=v$$(date +%Y).$$(( 10#$$(date +%m) )); \
	VERSION=$$PREFIX.$$(( $$(git tag -l "$$PREFIX.*" | wc -l) + 1 )); \
	echo "Poslední tag: $${LAST_TAG:-žádný} -> nový release: $$VERSION"; \
	USER=$$(id -un) claude -p "/release-notes $$VERSION" --permission-mode acceptEdits; \
	if [ -d project/sbom ]; then $(SUBMAKE) sbom; git status --short project/sbom/; fi; \
	git --no-pager diff $(RELEASE_NOTES); \
	echo -n "Je release $$VERSION v pořádku? [y/N] " && read ans && [ "$${ans:-N}" = y ]; \
	git add $(RELEASE_NOTES); \
	if [ -d project/sbom ]; then git add project/sbom/; fi; \
	git commit -m "Přidej release notes $$VERSION"; \
	git tag $$VERSION; \
	git push $$REMOTE HEAD $$VERSION

################################################################################
# Ostatní

# Node server v Playwright kontejneru leakuje browser contexty - běhy testů zabité uprostřed
# (timeout, Ctrl+C, pád) nepošlou after hook a procesy chromia zůstanou viset. Když roste RAM,
# stačí restart kontejneru.
.PHONY: playwright-restart
playwright-restart:
	@docker ps --format '{{.Names}}' | grep '^$(PROJECT_NAME)_playwright' | xargs -r docker restart

include $(ADT_MAKE_SELF)end.mk
