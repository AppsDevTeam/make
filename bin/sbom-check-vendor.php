<?php

declare(strict_types=1);

/**
 * Overi, ze nainstalovany vendor odpovida composer.lock.
 *
 * CycloneDX plugin sestavuje SBOM z vendor/composer/installed.json, ne z composer.lock. Kdyz
 * vendor driftuje (typicky po git pull nebo prepnuti vetve bez composer install), vygeneruje se
 * SBOM se starymi verzemi — tise, bez jakekoli chyby. V CI to pak spadne az na sbom-check, a to
 * uz muze byt po otagovani release.
 *
 * Porovnavaji se jen nedev balicky, protoze SBOM se generuje s --omit=dev; drift dev zavislosti
 * na jeho obsah nema vliv a nemel by proto blokovat generovani.
 *
 * Pouziti: php sbom-check-vendor.php [koren projektu] (bez argumentu aktualni adresar)
 */

$root = rtrim($argv[1] ?? getcwd(), '/');
$lockFile = $root . '/composer.lock';
$installedFile = $root . '/vendor/composer/installed.json';

foreach ([$lockFile, $installedFile] as $file) {
	if (!is_file($file)) {
		fwrite(STDERR, "Chybi $file — spust composer install.\n");
		exit(1);
	}
}

$lock = json_decode(file_get_contents($lockFile), true, flags: JSON_THROW_ON_ERROR);
$installed = json_decode(file_get_contents($installedFile), true, flags: JSON_THROW_ON_ERROR);

$installedVersions = [];
foreach ($installed['packages'] ?? [] as $package) {
	$installedVersions[$package['name']] = $package['version'];
}

$problems = [];
foreach ($lock['packages'] ?? [] as $package) {
	$name = $package['name'];
	$locked = $package['version'];

	if (!isset($installedVersions[$name])) {
		$problems[] = "$name: v locku $locked, ale neni nainstalovany";
	} elseif ($installedVersions[$name] !== $locked) {
		$problems[] = "$name: v locku $locked, nainstalovany {$installedVersions[$name]}";
	}
}

if ($problems) {
	fwrite(STDERR, "Vendor neodpovida composer.lock, SBOM by se vygeneroval se spatnymi verzemi:\n");
	foreach ($problems as $problem) {
		fwrite(STDERR, "  - $problem\n");
	}
	fwrite(STDERR, "Spust composer install a zkus to znovu.\n");
	exit(1);
}
