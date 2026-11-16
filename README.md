# adt/make

Sdílené make cíle webových projektů AppsDevTeam (šablona sandbox, Docker, Nette). Projekt má dál
tři makefily - v kořeni, v `project/` a v `docker/` - ale jen tenké: nastavení, vlastní cíle
a načtení tohoto balíčku. Oprava nebo nový cíl se tak dělá jednou tady, ne v kopiích ve všech
projektech.

Není to composer balíček: část cílů běží dřív, než existuje `vendor/` (`make config` na čerstvém
checkoutu), a `docker/makefile` pouští na serveru root v `~/docker`, kde `vendor/` není vůbec.
Makefile si proto tag stáhne sám (GitHub archiv, `curl` nebo `wget`) do `.make/<verze>/` vedle sebe
a make se po stažení spustí znovu.

## Zapojení

`config/.env.common` (odtud jde verze do `.env`, `docker/.env` i `project/.env`, po změně `make config`):

```
ADT_MAKE_VERSION=1.0.0
```

`.gitignore`:

```
.make/
```

Kořenový `makefile`:

```make
-include .env
export

# na čerstvém checkoutu bez .env se verze čte přímo z config/.env.common
ifndef ADT_MAKE_VERSION
ADT_MAKE_VERSION := $(shell sed -n 's/^ADT_MAKE_VERSION=//p' config/.env.common)
endif

# ... nastavení a cíle projektu ...

# deploy (adt/docker-deployer), před composer install chybí
-include project/vendor/adt/docker-deployer/make/deploy.mk

ADT_MAKE_DIR := $(or $(ADT_MAKE_DEV),.make/$(or $(ADT_MAKE_VERSION),$(error ADT_MAKE_VERSION chybí v config/.env.common)))
include $(ADT_MAKE_DIR)/root.mk
.make/%/root.mk:
	@echo "adt/make $*: stahuji do $(CURDIR)/.make/$*" >&2; u=https://github.com/AppsDevTeam/make/archive/refs/tags/v$*.tar.gz; t=$$(mktemp -d); \
	{ curl -fsSL $$u || wget -qO- $$u; } | tar xzf - -C $$t && mkdir -p .make && rm -rf .make/$* && mv $$t/* .make/$* && rmdir $$t
```

`project/makefile` a `docker/makefile` stejně, jen bez čtení `config/.env.common` (verzi mají
v `.env`) a s `project.mk` / `docker.mk` místo `root.mk`:

```make
-include .env
export

# ... nastavení a cíle projektu ...

ADT_MAKE_DIR := $(or $(ADT_MAKE_DEV),.make/$(or $(ADT_MAKE_VERSION),$(error ADT_MAKE_VERSION chybí v .env - spusť make config)))
include $(ADT_MAKE_DIR)/project.mk
.make/%/project.mk:
	@echo "adt/make $*: stahuji do $(CURDIR)/.make/$*" >&2; u=https://github.com/AppsDevTeam/make/archive/refs/tags/v$*.tar.gz; t=$$(mktemp -d); \
	{ curl -fsSL $$u || wget -qO- $$u; } | tar xzf - -C $$t && mkdir -p .make && rm -rf .make/$* && mv $$t/* .make/$* && rmdir $$t
```

Pravidla:

- **Balíček se načítá jako poslední.** Na konci (`end.mk`) jsou argumenty za `--`
  (`make deploy -- main`) převedené na prázdné cíle a to musí platit i pro cíle projektu.
- **Proměnné projektu před include**, balíček má výchozí hodnoty přes `?=`.
- **Cíl balíčku se nepřepisuje** (make by hlásil `overriding recipe`). Projekt mění chování
  proměnnými a háčky (pravidla s `::`, která se provedou všechna).
- **`$(SUBMAKE)` místo `$(MAKE)` v řádku receptu, který dělá i něco jiného.** Řádek s `$(MAKE)`
  make spustí i s `-n` (`make -n migrations` by migroval).

Vývoj balíčku: `ADT_MAKE_DEV=/absolutní/cesta/ke/klonu make ...` načte klon místo stažené verze
(PHP skripty z `bin/` ale běží v kontejneru, kam klon namountovaný není). Nová verze = tag
`vX.Y.Z` + GitHub release, v projektech `ADT_MAKE_VERSION` a `make config`.

## Kořen (`root.mk`)

| Cíl | |
|---|---|
| `config` | pracovní kopie pro `local` (`_env`; `CONFIG_STAGE=ci` v CI, které nemá klíč k šifrovanému `.env.local`), lokální hodnoty do `.env`, git hooky, remote `sandbox` (`SANDBOX_REMOTE`, prázdné = nepřidávat) |
| `config-claude N=<n>` | druhá izolovaná instance (`<projekt>_cl<n>-local`, bez publikovaných portů, bez sdílené proxy; s `CONFIG_CLAUDE_DOMAIN=www.projekt.loc` i doména `www.projekt_cl<n>.loc`) |
| `_env STAGE=<stage>` | `.env` v kořeni, `docker/` a `project/` z vrstev v `config/` (SOPS se rozšifruje), soubory stage, zašifrované JSON; háček `_env-after::`. Deploy ho pouští na serveru |
| `_tls-cert` | (součást `_env`) na stage `local`/`ci` vygeneruje self-signed certifikát nginxu pro `PROJECT_URL` (se SAN, 10 let) do `TLS_CERT_DIR` (`docker/nginx/etc/nginx/conf.d`), jen když chybí; necommituje se |
| `secrets-decrypt`, `secrets-encrypt` | `SECRETS_STAGE=<stage>\|all`, default aktuální `STAGE`; jen dotenv soubory `SOPS_FILES` (projekt zúží přes `override SOPS_FILES =`), další formáty přes háčky `secrets-decrypt-after::` / `secrets-encrypt-after::` |
| `_secrets-check` | pre-commit: nezašifrované citlivé hodnoty v `SOPS_CHECK_FILES` (default všechny stage) |
| `pre-commit` | celý git hook (`hooks/pre-commit` projektu je `exec make pre-commit`): opravy `PRE_COMMIT_FIX` (default `analyse-cs-fix`, opravené stagnuté soubory stagne znovu), pak kontroly `PRE_COMMIT_CHECKS` (default `analyse-cs analyse-sc test-coverage _secrets-check`) s PATH na obálky z `project/vendor/bin` |
| `release` | CalVer `vRRRR.M.N`, release notes přes `claude -p "/release-notes ..."` (`RELEASE_NOTES`), u CRA SBOM, commit + tag + push |
| `playwright-restart` | restart Playwright kontejnerů projektu |
| `help` (výchozí) | seznam cílů včetně přeposílaných |

Do `project/` se přeposílá: `analyse*`, `audit`, `build`, `checkout`, `clear`, `init`,
`migrations`, `migrations-diff`, `reload-consumers`, `sbom`, `sbom-check`, `test*`, `watch`
a cokoli z `PROJECT_MAKE_TARGETS`. Do `docker/`: `docker-*`, `audit-image` a `DOCKER_MAKE_TARGETS`.

Deploy (`make deploy`, `deploy-publish`, `deploy-unlock -- <stage>`) je v
[adt/docker-deployer](https://github.com/AppsDevTeam/docker-deployer) (`make/deploy.mk`), verze
cílů musí sedět s receptem.

## Aplikace (`project.mk`)

| Cíl | |
|---|---|
| `analyse`, `analyse-cs`, `analyse-cs-fix`, `analyse-sc` | phpcs (`CS_PATHS`), PHPStan (`PHPSTAN_PATHS`, `PHPSTAN_ARGS`) |
| `build`, `watch` | `yarn build:dev` lokálně, jinak `yarn build`; watch = `yarn $(YARN_WATCH)` (default `dev`) |
| `init`, `checkout`, `_prepare`, `clear` | instalace (composer v kontejneru `appsdevteam/php:<PHP_IMAGE>-composer`, na serveru `composer` z adt/docker-binaries), kontrola rozšíření PHP (`CHECK_EXTENSIONS`), reset opcache, temp, autoload. Deploy volá `_prepare`; `init` končí háčkem `init-after::` (založení DB, data) |
| `migrations` | viz níže |
| `migrations-diff` | `migrations:diff` + `MIGRATIONS_DIFF_ARGS` |
| `migrations-kill-sessions` | jen s `MIGRATIONS_KILL_SESSIONS = 1`: `dbal:kill-sessions` (adt/doctrine-components) před migracemi v údržbě |
| `reload-consumers` | `RELOAD_CONSUMERS` pro každý projekt, prázdné = nic |
| `test` | všechny suity (`tests/*.suite.yml`) paralelně, `TEST_ENV_<Suite>`, `TEST_BEFORE_<Suite>`, `TEST_SHARDS_<Suite>` |
| `test-suite SUITE=<S> [SHARD=i/N]` | jedna suita nebo její část (po celých Cestech, `bin/test-shard-files`) |
| `test-unit`, `test-acceptance [SHARD=i/N]`, `test-acceptance-retry`, `test-crawler`, `test-coverage`, `test-prepare` | |
| `audit`, `sbom`, `sbom-check` | composer + yarn audit, CycloneDX SBOM pro projekty pod CRA |

### Migrace

Deploy (recept adt/docker-deployer) volá `make migrations MIGRATIONS_DRY_RUN=1` (plán a řádek
`MIGRATIONS_PENDING`) a `make migrations MIGRATIONS_AUTO_CONFIRM=1`. Lokálně se migruje rovnou,
argumenty za `--` jdou do `migrations:migrate`. Prázdná DB jde bez dry-runu, pád dry-runu deploy
zastaví, v CI se migruje bez ptaní. Projekt bez adresáře `migrations/` má cíl prázdný
(`MIGRATIONS_ENABLED`).

Víc databází: `PROJECTS = <názvy>` (z `.env` i s uvozovkami) - migrace, `migrations-kill-sessions`
i `reload-consumers` se opakují pro každý projekt s `APP_ENV=project/<název>`. Kroky projektu:

| Proměnná / háček | Kdy |
|---|---|
| `MIGRATIONS_LOCAL_BEFORE`, `MIGRATIONS_LOCAL_AFTER` | lokálně před a po migracích každého projektu (např. založení DB, nalití dat) |
| `MIGRATIONS_AFTER` | po migracích každého projektu na všech stagích, ne v dry-runu |
| `migrations-before::`, `migrations-after::` | jednou před a po všech (např. společná DB); `MIGRATIONS_DRY_RUN` si hlídají samy |

Příklad (adt-dent, kliniky s vlastními DB a společná DB):

```make
PROJECTS = $(notdir $(basename $(wildcard config/project/*.neon)))
MIGRATIONS_KILL_SESSIONS = 1
MIGRATIONS_LOCAL_BEFORE = $(APP) database:create
MIGRATIONS_AFTER = $(APP) background-queue:update-schema
RELOAD_CONSUMERS = $(APP) background-queue:reload-consumers $(CONSUMERS)

migrations-before::
	@$(SUBMAKE) _migrations-deploy MIGRATIONS_COMMAND=migrations-shared APP_ENV= MIGRATIONS_LABEL='společná DB'
```

## Kontejnery (`docker.mk`)

`docker-up` (na popředí), `docker-upd`, `docker-upd-no-pull`, `docker-down`,
`audit-image` (Trivy, `IMAGE`). Lokálně porty na `PROJECT_IP` a volitelná sdílená proxy
adt/local-proxy (`LOCAL_PROXY`, `LOCAL_PROXY_DIR`).
