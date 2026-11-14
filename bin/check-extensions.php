<?php

declare(strict_types=1);

/**
 * Ověří, že PHP, ve kterém skript běží (runtime kontejner), má všechna rozšíření, která
 * vyžaduje projekt a nainstalované balíčky (ext-* v require).
 *
 * Proč: composer image (appsdevteam/php:*-composer) má COMPOSER_IGNORE_PLATFORM_REQ=ext-*,
 * takže `composer install` chybějící rozšíření nepozná. Runtime image je má z
 * install-composer-extensions (ONBUILD base image, viz docker/php/Dockerfile), jenže na
 * serveru ho přestavuje root (`make docker-upd`), ne deploy. Když release přinese balíček s novým rozšířením a image se
 * nepřestaví, deploy by prošel a aplikace by spadla až za běhu, v kódu, který rozšíření použije.
 * Kontrolu nenahradí ani vendor/composer/platform_check.php: ignorované požadavky vynechává
 * a rozšíření kontroluje jen s "platform-check": true.
 *
 * Kontroluje se podle vendor/composer/installed.json, tedy přesně to, co je nainstalované
 * (při --no-dev bez dev balíčků). Rozšíření, která některý balíček poskytuje (provide/replace,
 * typicky symfony/polyfill-*), se přeskakují stejně jako v Composeru.
 *
 * Použití: php check-extensions.php [kořen projektu] (bez argumentu aktuální adresář)
 */

$root = rtrim($argv[1] ?? getcwd(), '/');

$composerJson = json_decode(file_get_contents("$root/composer.json"), true, flags: JSON_THROW_ON_ERROR);
$vendorDir = $composerJson['config']['vendor-dir'] ?? 'vendor';
$installedFile = "$root/$vendorDir/composer/installed.json";

if (!is_file($installedFile)) {
	fwrite(STDERR, "Chybí $installedFile - spusť composer install.\n");
	exit(1);
}

$installed = json_decode(file_get_contents($installedFile), true, flags: JSON_THROW_ON_ERROR);
$withDev = (bool) ($installed['dev'] ?? true);

// Composer jméno rozšíření normalizuje na malá písmena a mezery nahrazuje pomlčkou
// (např. "Zend OPcache" je ext-zend-opcache).
$normalize = static fn (string $name): string => strtolower(str_replace(' ', '-', $name));

$required = [];
$provided = [];

$collect = static function (array $package, string $source) use (&$required, &$provided, $withDev): void {
	$requires = $package['require'] ?? [];
	if ($source === 'projekt' && $withDev) {
		$requires += $package['require-dev'] ?? [];
	}

	foreach ($requires as $name => $constraint) {
		if (str_starts_with($name, 'ext-')) {
			$required[strtolower(substr($name, 4))][] = $source;
		}
	}

	foreach (($package['provide'] ?? []) + ($package['replace'] ?? []) as $name => $constraint) {
		if (str_starts_with($name, 'ext-')) {
			$provided[strtolower(substr($name, 4))] = true;
		}
	}
};

$collect($composerJson, 'projekt');
foreach ($installed['packages'] ?? [] as $package) {
	$collect($package, $package['name']);
}

$loaded = array_map($normalize, array_merge(get_loaded_extensions(), get_loaded_extensions(true)));

$missing = [];
foreach ($required as $extension => $sources) {
	if (!isset($provided[$extension]) && !in_array($extension, $loaded, true)) {
		$missing[$extension] = array_unique($sources);
	}
}

if ($missing) {
	fwrite(STDERR, "PHP nemá rozšíření, která vyžaduje projekt nebo nainstalované balíčky:\n");
	foreach ($missing as $extension => $sources) {
		fwrite(STDERR, "  - ext-$extension (" . implode(', ', $sources) . ")\n");
	}
	fwrite(STDERR, "Runtime image je potřeba přestavět (make docker-upd), jinak aplikace spadne až za běhu.\n");
	exit(1);
}

echo 'Rozšíření PHP: všech ' . count($required) . " požadovaných je načtených.\n";
