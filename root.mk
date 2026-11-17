# Kořenový makefile projektu (viz README). Konfigurace (.env z config/), secrets (SOPS), release
# a přeposílání cílů do project/ a docker/. Deploy je v adt/docker-deployer (make/deploy.mk).

ADT_MAKE_SELF := $(dir $(lastword $(MAKEFILE_LIST)))
include $(ADT_MAKE_SELF)common.mk

SOPS ?= $(SUDO) sops

# Cíle, které jen přeposílá do project/ a docker/. Projekt přidá svoje přes PROJECT_MAKE_TARGETS
# a DOCKER_MAKE_TARGETS (definované před include).
ADT_PROJECT_TARGETS = analyse analyse-cs analyse-cs-fix analyse-sc audit build checkout clear debug-token init \
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

# CONFIG_STAGE: pracovní kopie pro jinou stage než local (CI: `make config CONFIG_STAGE=ci`,
# aby nepotřebovalo klíč k šifrovanému config/*/.env.local); lokální hodnoty níže se dosadí vždy
CONFIG_STAGE ?= local
.PHONY: config
config:
	@$(MAKE) --no-print-directory _env STAGE=$(CONFIG_STAGE)

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
	@for dir in docker project; do \
		find config/$$dir -type f \( -name "*$(STAGE)*" \) ! -name ".env*" | while read src; do \
			dest="$$dir/$${src#config/$$dir/}"; \
			mkdir -p "$$(dirname "$$dest")"; \
			cp -f "$$src" "$$dest"; \
		done; \
	done
	@# PHP načítá všechna ini v conf.d - pryč ini předchozí stage i stagí, které chytila maska
	@# výše jako podřetězec (STAGE=dev zkopíruje i default.csob-dev.ini); zůstane jen aktuální
	@find docker/php/usr/local/etc/php/conf.d -name 'default.*.ini' ! -name 'default.$(STAGE).ini' -delete 2>/dev/null || true

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
	@$(SUBMAKE) _tls-cert
	@$(MAKE) --no-print-directory _env-after

# Self-signed certifikát pro HTTPS nginxu na stage local a ci (stage/<stage>.conf, 443 a 1420).
# Necommituje se (privátní klíč v gitu hlásí každý sken secrets a byl stejný ve všech projektech),
# vznikne tady, jen když chybí: pro PROJECT_URL z docker/.env (víc domén čárkou: CN = první,
# SAN všechny), se SAN (bez něj ho prohlížeč
# neuzná ani po ručním přidání do důvěryhodných), na 10 let. Na main TLS řeší reverse proxy.
TLS_CERT_DIR ?= docker/nginx/etc/nginx/conf.d
.PHONY: _tls-cert
_tls-cert:
	@if [ "$(STAGE)" = local ] || [ "$(STAGE)" = ci ]; then \
		crt=$(TLS_CERT_DIR)/nginx-selfsigned.crt; key=$(TLS_CERT_DIR)/nginx-selfsigned.key; \
		if [ ! -f "$$crt" ] || [ ! -f "$$key" ]; then \
			hosts=$$(sed -n 's/^PROJECT_URL=//p' docker/.env | tail -1 | tr -d '"' | tr ',' ' '); hosts=$${hosts:-localhost}; \
			cn=$${hosts%% *}; san=$$(for h in $$hosts; do printf 'DNS:%s,' $$h; done); \
			openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$$cn" \
				-addext "subjectAltName=$${san}DNS:localhost" \
				-keyout "$$key" -out "$$crt" >/dev/null 2>&1 \
				|| { echo "Nepodařilo se vygenerovat TLS certifikát ($$crt) - chybí openssl?" >&2; exit 1; }; \
			chmod 600 "$$key"; \
			echo "TLS: vygenerován self-signed certifikát pro $$cn ($$crt)"; \
		fi; \
	fi

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
# Projekt může zúžit (override SOPS_FILES = ...), např. nešifrovat config/.env.local a .env.ci.
SOPS_FILES ?= $(shell find ./config -type f -name "*$(SOPS_STAGE_GLOB)" ! -name "*.env.common")
# Kontrola v pre-commit hooku (_secrets-check) - default všechny stage i .env.common (ten se
# nešifruje, secret v něm je chyba). Projekt, který šifruje jen některé (hesla dockerové DB local
# a ci v plaintextu), ho zúží.
SOPS_CHECK_FILES ?= $(shell find ./config -type f -name "*.env.*")
# `export` v makefilu projektu by find pouštěl u každého řádku každého receptu
unexport SOPS_FILES SOPS_CHECK_FILES

# Použití: make secrets-decrypt [SECRETS_STAGE=<stage>|all] - bez parametru aktuální STAGE.
# Deploy předává stage explicitně, aby ho nerozbil poškozený soubor cizí stage.
# Projektové kroky navíc (další šifrované soubory mimo dotenv, např. binární klíče):
# secrets-decrypt-after:: a secrets-encrypt-after:: v makefilu projektu (SECRETS_STAGE k dispozici).
.PHONY: secrets-decrypt secrets-encrypt secrets-decrypt-after secrets-encrypt-after _secrets-stage-check _secrets-check _sops-cat
secrets-decrypt: _secrets-stage-check
	@for file in $(SOPS_FILES); do \
		if grep -q "sops_mac" "$$file" 2>/dev/null; then \
			echo "Decrypting $$file"; \
			$(SOPS) decrypt --input-type dotenv --output-type dotenv -i "$$file"; \
		fi; \
	done
	@$(MAKE) --no-print-directory secrets-decrypt-after
secrets-decrypt-after::
	@:

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
	@$(MAKE) --no-print-directory secrets-encrypt-after
secrets-encrypt-after::
	@:

# Neexistující stage nesmí projít tiše - glob by nematchnul nic a target by skončil
# s exit 0, takže by se `make secrets-encrypt SECRETS_STAGE=<překlep>` tvářil jako úspěch
# a nechal na disku nezašifrovaná hesla
_secrets-stage-check:
	@if [ -n "$(filter-out all,$(SECRETS_STAGE))" ] && [ ! -f "config/.env.$(SECRETS_STAGE)" ]; then \
		echo "Neznámá stage '$(SECRETS_STAGE)' - config/.env.$(SECRETS_STAGE) neexistuje."; \
		echo "Dostupné: $(patsubst ./config/.env.%,%,$(wildcard ./config/.env.*)) all" | sed 's/ common//'; \
		exit 1; \
	fi

# Kontrola v pre-commit hooku - projíždí SOPS_CHECK_FILES bez ohledu na SECRETS_STAGE, řádek
# po řádku: proměnná s citlivým jménem (SECRETS_KEYS, bez ohledu na velikost písmen) a neprázdnou
# hodnotou musí být ENC[...]. Po řádcích, ne po souborech - s mac_only_encrypted by jinak prošla
# nová nezašifrovaná hodnota dopsaná do už zašifrovaného souboru. SECRETS_KEYS musí sedět
# s encrypted_regex v .sops.yaml (`(?i)(...)` se stejným výčtem), jinak hook pustí do gitu
# plaintext, který SOPS nešifruje, nebo spadne na proměnné, kterou zašifrovat neumí. Výjimky
# (veřejné "klíče" typu RECAPTCHA_SITE_KEY) dá projekt do SECRETS_ALLOW (regex celých jmen).
# Vypisuje jen soubor a jméno proměnné, hodnotu ne. Ostatní soubory hlídá gitleaks (_gitleaks-staged).
SECRETS_KEYS ?= PASS|PWD|SECRET|TOKEN|KEY|PRIVATE|DSN|AUTH|SALT|COOKIE
SECRETS_ALLOW ?=
_secrets-check:
	@found=$$(for file in $(SOPS_CHECK_FILES); do \
		grep -iE '^[A-Za-z0-9_]*($(SECRETS_KEYS))[A-Za-z0-9_]*=.' "$$file" 2>/dev/null | grep -v '=ENC\[' \
			| cut -d= -f1 $(if $(SECRETS_ALLOW),| grep -vxE '$(SECRETS_ALLOW)') | sed "s|^|$$file: |"; \
	done); \
	if [ -n "$$found" ]; then \
		printf 'Nezašifrované citlivé hodnoty (make secrets-encrypt SECRETS_STAGE=<stage>):\n%s\n' "$$found"; exit 1; \
	fi

# Gitleaks (známé formáty tokenů a klíčů) nad staged změnami - pokryje i soubory mimo config/
# (.yarnrc.yml, .npmrc, neon, compose). Bez sítě, repo jen pro čtení, hodnoty v hlášení redigované.
# secrets-scan totéž nad rozsahem commitů (CI: SECRETS_SCAN_RANGE=<base>..HEAD, prázdný = celá historie).
GITLEAKS_IMAGE ?= zricethezav/gitleaks:v8.30.1
# safe.directory: v CI (dind) patří repo jinému uživateli než procesu v kontejneru a git by odmítl číst
GITLEAKS = docker run --rm --network none -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory \
	-e GIT_CONFIG_VALUE_0='*' -v "$(CURDIR):/repo:ro" $(GITLEAKS_IMAGE)
.PHONY: _gitleaks-staged secrets-scan
_gitleaks-staged:
	@$(GITLEAKS) git --pre-commit --staged --redact --verbose --no-banner /repo
secrets-scan:
	@$(GITLEAKS) git --redact --verbose --no-banner $(if $(SECRETS_SCAN_RANGE),--log-opts="$(SECRETS_SCAN_RANGE)") /repo

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
# Pre-commit hook

# Kontroly před commitem - hooks/pre-commit projektu je jen `exec make pre-commit` (git ho pouští
# v kořeni repozitáře). Nejdřív automatické opravy PRE_COMMIT_FIX, pak cíle PRE_COMMIT_CHECKS;
# výstup kontroly se vypíše jen při chybě, commit projde, jen když prošly všechny. Projekt
# seznam mění před include, např. `PRE_COMMIT_CHECKS += analyse-deps`.
PRE_COMMIT_FIX ?= analyse-cs-fix
PRE_COMMIT_CHECKS ?= analyse-cs analyse-sc test-coverage _secrets-check _gitleaks-staged

# Soubory, které oprava změnila, se musí dostat i do commitu - git commituje index, ne pracovní
# adresář, a kontroly běží nad pracovním adresářem: neopravená verze by jinak prošla do gitu.
# Celý stagnutý soubor se stagne znovu; u částečně stagnutého (změny i mimo index) to bez
# rizika přidání cizích změn nejde, commit se proto zastaví.
#
# PATH: hook pouští i GitKraken nebo IDE bez PATH z ~/.bash_aliases - bez obálky php
# z adt/docker-binaries (project/vendor/bin) by phpcs a phpstan běžely v PHP hostu. Relativně
# jako v aliasu: obálka předá cestu skriptu do kontejneru, kde je project/ v /var/www/html.
.PHONY: pre-commit
pre-commit: export PATH := ./vendor/bin:./project/vendor/bin:$(PATH)
pre-commit:
	@diffs() { git diff --name-only | while read -r f; do echo "$$f $$(git diff -- "$$f" | git hash-object --stdin)"; done; }; \
	before=$$(diffs); \
	$(if $(PRE_COMMIT_FIX),$(SUBMAKE) $(PRE_COMMIT_FIX) >/dev/null 2>&1;) \
	staged=$$(git diff --cached --name-only --diff-filter=ACMR); partial=; \
	for f in $$(diffs | grep -vxF "$$before" | cut -d' ' -f1); do \
		printf '%s\n' "$$staged" | grep -qxF "$$f" || continue; \
		if printf '%s\n' "$$before" | grep -q "^$$f "; then partial="$$partial $$f"; else git add -- "$$f"; fi; \
	done; \
	if [ -n "$$partial" ]; then \
		printf '\033[31m%s\033[0m%s\n' "$(PRE_COMMIT_FIX) upravil částečně stagnuté soubory, zkontroluj a stagni je:" "$$partial"; exit 1; \
	fi; \
	failed=; n=0; total=$(words $(PRE_COMMIT_CHECKS)); \
	for t in $(PRE_COMMIT_CHECKS); do \
		n=$$((n + 1)); printf '\033[33m[%s/%s]\033[0m %-22s' $$n $$total $$t; \
		if out=$$($(SUBMAKE) $$t 2>&1); then printf '\033[32mOK\033[0m\n'; \
		else printf '\033[31mCHYBA\033[0m\n\n%s\n\n' "$$out"; failed=1; fi; \
	done; \
	[ -z "$$failed" ]

################################################################################
# Release

# Verze vRRRR.M.N (rok, měsíc od 1, pořadí releasu v měsíci od 1). Release notes dopíše Claude:
# s ANTHROPIC_API_KEY přes API (bin/release-notes.py - CI, adt/ci po publishi vydá tag a GitLab
# Release), jinak claude CLI (skill /release-notes projektu). `make release` je lokální varianta
# bez CD: notes, u projektu pod CRA (existuje project/sbom/) SBOM, po odsouhlasení commit, tag
# a push. Deploy zůstává samostatný krok.
#
# Remote se bere z upstreamu aktuální větve: v odvozeném projektu je to origin, v repu samotného
# sandboxu sandbox (origin tam není, jen by duplikoval stejnou URL).
#
# USER=$(id -un) u claude: `.env` obsahuje USER=<uid> pro Docker a `export` v makefilu projektu
# ho protlačí do všech podprocesů. Claude pak hledá přihlášení pod účtem "501" a hlásí "Not logged in".
# Přihlašovací jméno mu proto vrátíme jen pro tenhle příkaz.
RELEASE_NOTES ?= docs/release-notes.md
RELEASE_NOTES_MODEL ?= claude-opus-5-5
# Příští verze: tagy v aktuálním měsíci + 1 (před voláním git fetch --tags)
define release_version
PREFIX=v$$(date +%Y).$$(( 10#$$(date +%m) )); echo $$PREFIX.$$(( $$(git tag -l "$$PREFIX.*" | wc -l) + 1 ))
endef
.PHONY: release-version release-notes release
release-version:
	@$(release_version)

# make release-notes [VERSION=vRRRR.M.N] - jen záznam do RELEASE_NOTES, bez commitu
release-notes:
	@set -e; VERSION=$${VERSION:-$$($(release_version))}; \
	if [ -n "$$ANTHROPIC_API_KEY" ]; then \
		python3 $(ADT_MAKE_SELF)bin/release-notes.py "$$VERSION" "$(RELEASE_NOTES)" "$(RELEASE_NOTES_MODEL)"; \
	else \
		command -v claude >/dev/null || { echo "claude CLI není nainstalované (nebo nastav ANTHROPIC_API_KEY)"; exit 1; }; \
		USER=$$(id -un) claude -p "/release-notes $$VERSION" --permission-mode acceptEdits; \
	fi

release:
	@git diff --quiet && git diff --cached --quiet || { echo "Working tree není čistý - commitni nebo stashni změny."; exit 1; }
	@set -e; \
	REMOTE=$$(git config "branch.$$(git branch --show-current).remote" || true); \
	[ -n "$$REMOTE" ] || { echo "Aktuální větev nesleduje žádný remote (git branch --set-upstream-to=...)."; exit 1; }; \
	git fetch --tags $$REMOTE; \
	LAST_TAG=$$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true); \
	VERSION=$$($(release_version)); \
	echo "Poslední tag: $${LAST_TAG:-žádný} -> nový release: $$VERSION"; \
	$(MAKE) --no-print-directory release-notes VERSION=$$VERSION; \
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
