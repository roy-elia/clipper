#!/bin/zsh
# Runs the tests and fails if none ran (bare `swift test` can pass with zero tests).
# Command Line Tools ship Swift Testing outside the default search path, so pass it explicitly.
cd "$(dirname "$0")/.." || exit 1
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
U=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
out=$(swift test -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $U 2>&1); code=$?
print -r -- "$out" | grep -E 'error:|✘|Test run|Suite .* (passed|failed)' | head -20
n=$(print -r -- "$out" | grep -Eo 'Test run with [0-9]+ tests?' | tail -1 | grep -Eo '[0-9]+')
echo "tests run: ${n:-0}  exit: $code"
[[ $code -ne 0 || -z "$n" || "$n" -eq 0 ]] && exit 1
exit 0
