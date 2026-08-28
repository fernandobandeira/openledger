#!/usr/bin/env python3
"""Spike 021 — build the static API-reference pages.

The spec is INLINED into each page rather than fetched. That is the whole point
of the exercise: a static host serves files, and a page that does
`fetch('openapi.json')` is one CORS rule, one base-path change or one `file://`
preview away from rendering an empty shell. Inlining removes the request.

The pages are generated from `spec/openapi.utoipa.json`, so there is no third
copy of the contract to keep in step.

    python3 render/build.py
"""

import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
SPEC = ROOT / "spec" / "openapi.utoipa.json"

spec_json = json.dumps(json.loads(SPEC.read_text()), indent=2)
# `</script>` inside a <script> block ends it. The spec has no such string today;
# escape anyway, because a description someday will.
spec_json = spec_json.replace("</", "<\\/")

REDOC = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenLedger write path — Redoc</title>
<style>body {{ margin: 0; }}</style>
</head>
<body>
<div id="redoc"></div>
<script type="application/json" id="openapi-spec">
%SPEC%
</script>
<script src="https://cdn.redoc.ly/redoc/v2.5.3/bundles/redoc.standalone.js"></script>
<script>
  var spec = JSON.parse(document.getElementById('openapi-spec').textContent);
  Redoc.init(spec, {{ hideDownloadButton: false, expandResponses: '201,422' }},
             document.getElementById('redoc'));
</script>
</body>
</html>
"""

SCALAR = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenLedger write path — Scalar</title>
<style>body {{ margin: 0; }}</style>
</head>
<body>
<div id="app"></div>
<script type="application/json" id="openapi-spec">
%SPEC%
</script>
<script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference@1.66.1"></script>
<script>
  var spec = JSON.parse(document.getElementById('openapi-spec').textContent);
  Scalar.createApiReference('#app', {{ content: spec, hideModels: false }});
</script>
</body>
</html>
"""

for name, tpl in (("redoc.html", REDOC), ("scalar.html", SCALAR)):
    out = HERE / name
    out.write_text(tpl.replace("{{", "{").replace("}}", "}").replace("%SPEC%", spec_json))
    print(f"wrote {out} ({out.stat().st_size} bytes)")
