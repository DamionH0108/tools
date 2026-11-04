#!/bin/bash
# Run interactively as the signed-in user, never via sudo.
set -eu
umask 077
here=$(cd "$(dirname "$0")" && pwd)
exec /usr/bin/python3 "$here/prepare_environment.py"
