#!/bin/sh
# Build logshipper with the Free Pascal Compiler (FPC).
set -e
fpc -Mobjfpc -Sh -O2 -vewnhi -Fu. logshipper.lpr
echo "built: logshipper"
