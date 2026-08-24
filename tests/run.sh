#!/bin/sh

set -u

failures=0
suites=0

for suite in tests/*_test.sh; do
    [ -f "$suite" ] || continue
    suites=$((suites + 1))

    if sh "$suite"; then
        printf '%s\n' "PASS: $suite"
    else
        printf '%s\n' "FAIL: $suite" >&2
        failures=$((failures + 1))
    fi
done

printf '%s\n' "Suites: $suites, failures: $failures"
[ "$failures" -eq 0 ]
