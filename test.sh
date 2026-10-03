#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
hw-odin test "$ROOT" -vet -strict-style -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -define:ODIN_TEST_THREADS=1
python3 "$ROOT/scripts/check_release.py"
