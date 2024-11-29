set shell := ["bash", "-uc"]
set positional-arguments

project := 'aoc-2024'

# show this help
help:
	@just --list

# configure the dev environment
configure-dev:
  @echo "⬇️  installing tools (nothing so far...)"
  @echo "👌 done, happy hacking!"

# validate a day `just validate 1`
validate *arg:
	@zig test src/day{{arg}}.zig 2>&1 | cat
