# Makefile kontejnerů (adresář docker/, viz README). Lokálně, v CI a na serveru, kde ho v ~/docker
# pouští root (`make docker-upd`) - deploy kontejnery nepřestavuje.

ADT_MAKE_SELF := $(dir $(lastword $(MAKEFILE_LIST)))
include $(ADT_MAKE_SELF)common.mk

DOCKER_COMPOSE ?= docker compose -f docker-compose.yml -f docker-compose.$(STAGE).yml -p $(PROJECT_NAME)

# Sdílená Traefik proxy (adt/local-proxy) je lokálně volitelná. Když běží nebo je naklonovaná
# (hledá se v ~, případně LOCAL_PROXY_DIR=<cesta>), jde HTTP/HTTPS přes ni podle domény
# (docker-compose.local-proxy.yml); jinak nginx publikuje 80/443 sám na PROJECT_IP.
# LOCAL_PROXY=1 / LOCAL_PROXY=0 volbu vynutí (make config-claude dává izolované instanci 0).
# Proměnné jsou `:=` - `export` na začátku souboru by jinak `find` pouštěl u každého řádku
# receptu. `find` běží, jen když proxy neběží, cesta není zadaná a proxy není vypnutá.
ifeq ($(STAGE),local)
LOCAL_PROXY_RUNNING := $(shell docker ps -q --filter name=^local_proxy$$)
ifeq ($(LOCAL_PROXY_RUNNING)$(LOCAL_PROXY_DIR),)
ifneq ($(LOCAL_PROXY),0)
LOCAL_PROXY_DIR := $(shell find ~ -maxdepth 5 -type f -name projects.yml -path '*/local-proxy/*' 2>/dev/null | head -1 | sed 's|/projects.yml$$||')
endif
endif
ifeq ($(LOCAL_PROXY),)
LOCAL_PROXY := $(if $(LOCAL_PROXY_RUNNING)$(LOCAL_PROXY_DIR),1,0)
endif
ifeq ($(LOCAL_PROXY),1)
DOCKER_COMPOSE += -f docker-compose.local-proxy.yml
endif
endif

################################################################################
# TARGETS

.PHONY: docker-down docker-up docker-upd docker-upd-no-pull _docker-upd-no-build audit-image _docker-common _docker-local-only _docker-stop-before-up
docker-down: _docker-local-only
	$(DOCKER_COMPOSE) down

docker-up: _docker-local-only _docker-common _docker-stop-before-up
	$(DOCKER_COMPOSE) up --force-recreate --build

docker-upd: _docker-local-only _docker-common _docker-stop-before-up
	$(DOCKER_COMPOSE) up -d --force-recreate --build

docker-upd-no-pull: _docker-local-only _docker-stop-before-up
	$(DOCKER_COMPOSE) up -d --force-recreate --build

# `--force-recreate` přetvoří i frontu (rabbitmq), zatímco consumery v supervisoru dál běží - během
# té díry se restartují ve smyčce a každý pád zaloguje "Unable to connect" (depends_on platí jen při
# startu, ne při recreate pod běžícím dependentem). Proto se zastaví předem, `up` je pustí znovu.
# Jen služby, které projekt v compose má.
DOCKER_STOP_BEFORE_UP ?= supervisor
_docker-stop-before-up:
	@have=$$($(DOCKER_COMPOSE) config --services 2>/dev/null); \
	stop=$$(for s in $(DOCKER_STOP_BEFORE_UP); do printf '%s\n' "$$have" | grep -qxF "$$s" && echo "$$s"; done); \
	[ -z "$$stop" ] || $(DOCKER_COMPOSE) stop $$stop || true

_docker-upd-no-build: _docker-local-only
	$(DOCKER_COMPOSE) up -d --force-recreate

# Kontejnery na serverech spravuje dupd (adt/docker-binaries: `sudo dupd build|up` z účtu
# projektu, root `dupd -u <projekt> up`, deploy ho volá sám), ne tyhle cíle. ~/docker (makefile,
# .env, compose, .make/) patří účtu projektu: root, který v něm spustí make nebo docker compose,
# vykoná kód, který mohl účet upravit - eskalace na roota. Mimo local a ci proto končí chybou.
_docker-local-only:
	@if [ "$(STAGE)" != local ] && [ "$(STAGE)" != ci ]; then \
		echo "make $(MAKECMDGOALS): na stage $(STAGE) kontejnery spravuje dupd - sudo dupd build && sudo dupd up (root: dupd -u <projekt> up), viz README adt/docker-binaries" >&2; \
		exit 1; \
	fi

################################################################################
# TARGETS — bezpečnost

# Audit zranitelností OS balíčků v image.
# `make audit` řeší závislosti aplikace (composer/yarn), tenhle cíl to, co je v image.
# --ignore-unfixed: hlásí jen to, na co existuje oprava, tedy akceschopné nálezy.
# Když cíl začne padat, řeší se to v Dockerfile (nebo novější verzí base image), ne výjimkou.
# IMAGE lze přepsat: make audit-image IMAGE=$CI_REGISTRY_IMAGE/php:master
IMAGE ?= $(PROJECT_NAME)-php:latest
# Pevná verze a digest (plovoucí latest by do auditu podstrčil cokoli). Trivy nedostane socket
# Dockeru (s ním by měl root nad celým hostem) - skenuje archiv z `docker save`, jen pro čtení.
# Archiv v adresáři projektu, ne v /tmp: v CI démon běží v dind službě a /tmp jobu nevidí.
TRIVY_IMAGE ?= aquasec/trivy:0.76.2@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb
audit-image:
	@tmp=$$(mktemp -d "$(CURDIR)/.audit-image.XXXXXX"); trap 'rm -rf "$$tmp"' EXIT; \
	docker save $(IMAGE) -o "$$tmp/image.tar" && chmod -R a+rX "$$tmp" && \
	docker run --rm \
		-v "$$tmp/image.tar:/image.tar:ro" \
		-v trivy-cache:/root/.cache \
		$(TRIVY_IMAGE) image \
		--input /image.tar \
		--scanners vuln \
		--severity HIGH,CRITICAL \
		--ignore-unfixed \
		--skip-version-check \
		--exit-code 1

################################################################################
# HELPERS

_docker-common:
	@# eohd (docker/bin/eohd projektů do adt/make 1.0.x) poslouchal na všech rozhraních a příkazy
	@# z portu NC_PORT pouštěl přes eval - kdokoli ze stejné sítě mohl spustit příkaz na stroji
	@# vývojáře. Nahrazovat se nebude (otevíral jen laděnku konzole v prohlížeči hostu, a to
	@# ani nefungovalo), tady se jen ukončí běžící instance všech projektů i s jejich nc. Nejdřív
	@# děti (nc běží v podshellu eohd, po zabití rodiče by osiřel), pak osiřelé nc z dřívějška.
	@if [ "$(STAGE)" = 'local' ]; then \
		pids=$$(pgrep -f '/eohd$$' 2>/dev/null); \
		for pid in $$pids; do pkill -P $$pid 2>/dev/null; done; \
		[ -z "$$pids" ] || kill $$pids 2>/dev/null; \
		for pid in $$(pgrep -f '^nc -l (172\.17\.0\.1 -p )?[0-9]+$$' 2>/dev/null); do \
			[ "$$(ps -o ppid= -p $$pid | tr -d ' ')" = 1 ] && kill $$pid 2>/dev/null; \
		done; true; \
	fi

	@# Lokálně jsou porty na loopback IP projektu (PROJECT_IP) - na macOS musí existovat alias
	@# na lo0, jinak compose skončí na bindu. Při práci přes sdílenou proxy (LOCAL_PROXY=1, viz
	@# začátek souboru) se neběžící proxy spustí.
	@if [ "$(STAGE)" = 'local' ]; then \
		if [ "$$(uname)" = "Darwin" ] && ! ifconfig lo0 | grep -qw "inet $(PROJECT_IP)"; then \
			echo "Na lo0 chybí alias $(PROJECT_IP) - sudo ifconfig lo0 alias $(PROJECT_IP) up (nebo v local-proxy make loopback-aliases)" >&2; \
			exit 1; \
		fi; \
		if [ "$(LOCAL_PROXY)" != 1 ]; then \
			echo "Bez sdílené proxy (adt/local-proxy): nginx publikuje 80/443 na $(PROJECT_IP)"; \
		elif [ -z "$(LOCAL_PROXY_RUNNING)" ]; then \
			if [ -z "$(LOCAL_PROXY_DIR)" ]; then \
				echo "LOCAL_PROXY=1, ale klon local-proxy jsem nenašel - git clone ssh://git@git.appsdevteam.com:2222/adt/local-proxy.git, případně LOCAL_PROXY_DIR=<cesta> (viz README)" >&2; \
				exit 1; \
			fi; \
			$(SUBMAKE) -C "$(LOCAL_PROXY_DIR)" up; \
		fi; \
	fi

	@# composer.json a composer.lock pro php/Dockerfile (install-composer-extensions) - mimo
	@# build context ./php. Lokálně je project/ plochý adresář vedle docker/, zkopírujeme je
	@# odtud (CI builduje přes `docker build` a kopíruje si je samo v .gitlab-ci.yml).
	@# Na produkci je nakopíruje deploy.php spolu s docker/ složkou - tam ../project
	@# neexistuje jako plochý adresář (je to Deployerem spravovaný strom s releases/current),
	@# takže se tahle kopie přeskočí a zůstane to, co tam dal deploy.
	@[ -f ../project/composer.json ] && cp ../project/composer.json ../project/composer.lock php/ || true

	$(DOCKER_COMPOSE) build --pull

include $(ADT_MAKE_SELF)end.mk
