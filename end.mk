# Konec kořenového, projektového i dockerového makefilu - musí se načíst jako poslední.
#
# Převede všechny RUN_ARGS do formy
#   <arg1> <arg2>:;@:
# tedy na cíle, které nic nedělají (make deploy -- main nesmí hledat cíl `main`). Když se argument
# shoduje s názvem existujícího cíle, spustily by se oba - pravidlo proto musí být poslední, aby
# recept druhého cíle přepsalo na prázdný. Dolary v argumentu by eval expandoval, proto se zdvojují.
$(eval $(subst $$, $$$$, $(RUN_ARGS)):;@:)
