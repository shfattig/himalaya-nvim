min_coverage := "90"

_nix := "nix develop --command"
_gen := _nix + " nvim --headless -l scripts/gen-docs.lua"

# Run all CI checks
check: _parallel-checks _coverage-check _gen-docs-check

[private]
_parallel-checks:
    {{ _nix }} parallel --tagstring '[{#}:{=s/ .*//=}]' --line-buffer ::: \
        'nix fmt -- --fail-on-change' \
        'luacheck lua/ tests/'

# Generate docs (--bump, --salt=X, --salt= to manage cache version)
gen-docs *args:
    {{ _gen }} {{ args }}

[private]
_gen-docs-check: gen-docs
    @git diff --exit-code README.md CONTRIBUTING.md || \
        (echo ""; echo "FAIL: docs are out of date — run 'just gen-docs' and commit the result"; exit 1)

# Run tests
test:
    {{ _nix }} busted

# Run performance benchmarks
perf:
    @rm -f perf-results.json
    {{ _nix }} busted --run perf
    @echo ""
    @echo "── results written to perf-results.json ──"
    @python3 -m json.tool perf-results.json 2>/dev/null || cat perf-results.json

# Generate coverage report
coverage:
    @rm -f luacov.stats.out luacov.report.out
    LUACOV=1 {{ _nix }} busted
    {{ _nix }} luacov
    @echo ""
    @echo "Coverage report: luacov.report.out"

[private]
_coverage-check: coverage
    @awk '/^lua\/himalaya\/.*\.lua\s/ { \
        split($0, a); pct = a[length(a)]; gsub(/%/, "", pct); \
        if (pct + 0 < {{ min_coverage }}) { printf "FAIL: %s at %s%% (min {{ min_coverage }}%%)\n", a[1], pct; fail=1 } \
    } END { if (fail) exit 1; print "Each file >= {{ min_coverage }}% coverage" }' luacov.report.out

# Run linter
lint:
    {{ _nix }} luacheck lua/ tests/

# Format code
fmt:
    nix fmt

# Run NixOS integration test and update fixtures from VM output
fixtures:
    nom build .#checks.x86_64-linux.integration
    rm -rf tests/fixtures/json tests/fixtures/plain
    cp -r result/fixtures/json result/fixtures/plain tests/fixtures/

# Regenerate diag hook logs from NixOS VM
diag-logs:
    nom build .#checks.x86_64-linux.diag-hooks
    rm -f scripts/diag-hooks/*.log
    cp result/diag-logs/*.log scripts/diag-hooks/
