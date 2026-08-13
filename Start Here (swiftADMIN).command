#!/bin/bash
# Double-clicking a .command file is macOS's native way to open Terminal
# and run a script inside it -- no special app bundle or compilation
# needed, just a plain shell script with this specific extension.
#date created - 08/13/26
cd "$(dirname "$0")/swiftADMIN"
python3 swiftADMIN.py
