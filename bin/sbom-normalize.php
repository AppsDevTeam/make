<?php

declare(strict_types=1);

/**
 * Normalizuje CycloneDX SBOM pro reprodukovatelnost napric prostredimi (local vs CI).
 * SBOM se commituje do repa (viz README, sekce Bezpecnost a CRA), takze nesmi obsahovat nic, co se lisi
 * podle prostredi nebo aktualniho git stavu:
 *
 *  - metadata.tools — verze composeru/yarnu/pluginu z konkretniho prostredi
 *  - dist/source reference root komponenty — SHA aktualniho HEAD (menil by se kazdym commitem)
 *  - externalReferences — URL se ctou z vendor/composer/installed.json, ktery muze driftovat
 *    vuci composer.lock (napr. prejmenovani GitHub repa u kreait/firebase-tokens);
 *    pro identifikaci komponent staci purl + verze + licence
 *  - verze root komponenty — composer ji hada z gitu (dev-main na branch, ale vX.Y.Z kdyz
 *    checkout ukazuje na tag), takze COMPOSER_ROOT_VERSION nestaci; sjednotime na dev-main
 *
 * Pouziti: php bin/sbom-normalize.php <soubor.cdx.json> [...]
 */

const ROOT_VERSION = 'dev-main';

$stripComponent = function (array &$component) use (&$stripComponent): void {
	unset($component['externalReferences']);

	if (isset($component['properties'])) {
		$component['properties'] = array_values(array_filter(
			$component['properties'],
			fn(array $property) => !in_array($property['name'], [
				'cdx:composer:package:distReference',
				'cdx:composer:package:sourceReference',
			], true),
		));
		if (!$component['properties']) {
			unset($component['properties']);
		}
	}

	if (isset($component['components'])) {
		foreach ($component['components'] as &$subComponent) {
			$stripComponent($subComponent);
		}
	}
};

foreach (array_slice($argv, 1) as $file) {
	$sbom = json_decode(file_get_contents($file), true, flags: JSON_THROW_ON_ERROR);

	unset($sbom['metadata']['tools']);

	if (isset($sbom['metadata']['component'])) {
		$root = &$sbom['metadata']['component'];
		$oldRef = $root['bom-ref'] ?? null;
		$newRef = isset($root['bom-ref']) ? $root['name'] . '-' . ROOT_VERSION : null;

		if (isset($root['version'])) {
			$root['version'] = ROOT_VERSION;
		}
		if (isset($root['purl'])) {
			$root['purl'] = 'pkg:composer/' . $root['name'] . '@' . ROOT_VERSION;
		}
		if ($newRef !== null) {
			$root['bom-ref'] = $newRef;
		}
		unset($root);

		if ($oldRef !== null && $newRef !== null && isset($sbom['dependencies'])) {
			foreach ($sbom['dependencies'] as &$dependency) {
				if (($dependency['ref'] ?? null) === $oldRef) {
					$dependency['ref'] = $newRef;
				}
			}
			unset($dependency);
		}

		$stripComponent($sbom['metadata']['component']);
	}
	if (isset($sbom['components'])) {
		foreach ($sbom['components'] as &$component) {
			$stripComponent($component);
		}
		unset($component);
	}

	file_put_contents(
		$file,
		json_encode($sbom, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR) . "\n",
	);
}
