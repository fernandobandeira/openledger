#!/usr/bin/env bash
# How many top-level OR disjuncts does card_hold_drift actually have?
cd "$(dirname "$0")/../.." || exit 1
awk '/^CREATE VIEW card_hold_drift/,0' parked/card/schema.sql \
  | awk '/^WHERE /,0' | grep -vE '^\s*--' | grep -nE '^(WHERE|   OR) ' | cut -c1-90
