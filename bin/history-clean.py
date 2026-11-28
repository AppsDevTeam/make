#!/usr/bin/env python3
"""Plán přepisu historie z JSON reportu gitleaks (cíle history-scan / history-clean adt/make).

    history-clean.py plan <report.json> [<výstupní adresář>] [<soubor s dalšími náhradami>]

Vypíše tabulku nálezů (hodnoty maskované) a do výstupního adresáře zapíše replace.txt pro
`git filter-repo --replace-text` a paths.txt se soubory, které se z historie smažou celé.
Návratový kód: 0 = je co přepsat, 1 = nález, který nástroj neumí (ruční zásah), 2 = čistá historie.
"""

import json
import os
import re
import sys

REPLACEMENT = b"***REMOVED***"
DOTENV_RULE = "adt-dotenv-secret"
# Soubor s klíčem se maže celý - vícerádkový secret nejde nahradit po řádcích
KEY_SUFFIXES = (".key", ".pem", ".p12", ".pfx", ".ppk", ".jks", ".crt", ".cer")
# Kratší literál by se nahrazoval i tam, kde není secret (slovo "root" v kódu)
MIN_LITERAL = 8


def mask(secret):
	s = secret.replace("\n", "\\n")
	return (s[:2] + "…" if len(s) > 2 else "…") + f" ({len(secret)} zn.)"


def dotenv_name(match):
	line = re.sub(r"^[ \t]*(export[ \t]+)?", "", match)
	return line.split("=", 1)[0].strip()


def plan(report_path, out_dir=None, extra_path=None):
	with open(report_path, encoding="utf-8") as f:
		findings = json.load(f) or []
	if not findings:
		print("history-scan: gitleaks v historii nic nenašel")
		return 2

	literals = {}   # secret -> popis
	regexes = {}    # řádek replace.txt -> popis
	paths = {}      # soubor -> popis
	manual = []
	rows = []
	for f in findings:
		rule, file, commit = f["RuleID"], f["File"], f["Commit"][:7]
		secret, match = f["Secret"], f.get("Match", "")
		where = f"{file} @ {commit}"
		if rule == "private-key" or "\n" in secret:
			if file.lower().endswith(KEY_SUFFIXES):
				paths[file] = where
				action = "smazat soubor z historie"
			else:
				manual.append(f"{where}: vícerádkový secret ({rule}) v souboru, který se nemaže celý - nahraď ručně (HISTORY_CLEAN_EXTRA)")
				action = "RUČNĚ"
		elif rule == DOTENV_RULE:
			name = dotenv_name(match)
			if not re.fullmatch(r"[A-Za-z0-9_]+", name):
				manual.append(f"{where}: nečekané jméno proměnné {name!r}")
				action = "RUČNĚ"
			else:
				line = (
					b"regex:(?m)^([ \\t]*(?:export[ \\t]+)?" + name.encode() + b"[ \\t]*=[ \\t]*[\"']?)"
					+ re.escape(secret.encode()) + b"([\"']?[ \\t\\r]*)$==>\\1" + REPLACEMENT + b"\\2"
				)
				regexes[line] = where
				action = f"nahradit hodnotu {name} na řádku proměnné"
		elif len(secret) >= MIN_LITERAL:
			literals[secret.encode()] = where
			action = "nahradit všude v historii"
		else:
			manual.append(f"{where}: secret kratší než {MIN_LITERAL} znaků ({rule}) - nahrazení všude by poškodilo i jiný obsah, nahraď ručně (HISTORY_CLEAN_EXTRA) nebo vyřaď přes .gitleaksignore")
			action = "RUČNĚ"
		rows.append((rule, where, mask(secret), action, f.get("Fingerprint", "")))

	w = [max(len(r[i]) for r in rows) for i in range(4)]
	print("history-scan: nálezy gitleaks v historii (hodnoty maskované):")
	for r in rows:
		print("  " + "  ".join(r[i].ljust(w[i]) for i in range(4)))
	print("\nFalešný nález vyřadí řádek s otiskem v .gitleaksignore (platí jen do přepisu, pak se hashe změní):")
	for r in rows:
		print(f"  {r[4]}")

	if manual:
		print("\nhistory-scan: tyhle nálezy nástroj sám neopraví:", file=sys.stderr)
		for m in manual:
			print("  " + m, file=sys.stderr)
		return 1

	if out_dir:
		fd = os.open(os.path.join(out_dir, "replace.txt"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
		with os.fdopen(fd, "wb") as out:
			for secret in literals:
				out.write(secret + b"==>" + REPLACEMENT + b"\n")
			for line in regexes:
				out.write(line + b"\n")
			if extra_path:
				with open(extra_path, "rb") as extra:
					out.write(extra.read().rstrip(b"\n") + b"\n")
		with open(os.path.join(out_dir, "paths.txt"), "w", encoding="utf-8") as out:
			out.write("".join(p + "\n" for p in paths))
	print(f"\nhistory-scan: {len(literals)} hodnot k nahrazení všude, {len(regexes)} hodnot proměnných, {len(paths)} souborů ke smazání z historie")
	return 0


if __name__ == "__main__":
	if len(sys.argv) < 3 or sys.argv[1] != "plan":
		print(__doc__, file=sys.stderr)
		sys.exit(64)
	sys.exit(plan(sys.argv[2], *sys.argv[3:5]))
