#!/usr/bin/env python3
"""Extract JSON schemas from CustomResourceDefinitions, for kubeconform.

Reads a stream of concatenated JSON objects on stdin — which is what
`kubectl create -f ... --dry-run=client -o json` emits for a multi-document file —
and writes one schema per CRD version to:

    <out_dir>/<group>/<kind lowercased>_<version>.json

That layout is not arbitrary: it is what kubeconform's default
`{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json` template resolves to, and
it matches the datreeio/CRDs-catalog convention, so the same -schema-location string
works against either.

Standard library only. The lab already depends on python3 being present; it should not
also depend on a YAML package that may or may not be installed next to it.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def iter_json_objects(text: str):
    """Yield each object from a stream of concatenated JSON documents."""
    decoder = json.JSONDecoder()
    index = 0
    length = len(text)
    while index < length:
        while index < length and text[index].isspace():
            index += 1
        if index >= length:
            return
        obj, index = decoder.raw_decode(text, index)
        yield obj


def schema_for(crd: dict, version: dict) -> dict:
    """Build a standalone JSON schema for one version of one CRD."""
    spec = crd["spec"]
    group = spec["group"]
    kind = spec["names"]["kind"]

    schema = dict(version.get("schema", {}).get("openAPIV3Schema") or {"type": "object"})

    # The structural schema in a CRD describes the *body* of the resource and leaves
    # apiVersion/kind/metadata to the API machinery. kubeconform validates the whole
    # document, so those three have to be put back or every manifest fails on fields
    # the schema has never heard of.
    properties = dict(schema.get("properties") or {})
    properties.setdefault("apiVersion", {"type": "string", "const": f"{group}/{version['name']}"})
    properties.setdefault("kind", {"type": "string", "const": kind})
    properties.setdefault("metadata", {"type": "object"})
    schema["properties"] = properties
    schema.setdefault("type", "object")
    schema["$schema"] = "http://json-schema.org/draft-07/schema#"

    return schema


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <out_dir>", file=sys.stderr)
        return 2
    out_dir = Path(sys.argv[1])

    written = 0
    for doc in iter_json_objects(sys.stdin.read()):
        if doc.get("kind") != "CustomResourceDefinition":
            continue

        spec = doc["spec"]
        group = spec["group"]
        kind = spec["names"]["kind"]

        for version in spec.get("versions", []):
            # A CRD may carry versions that exist only to be converted from. Writing a
            # schema for one would let kubeconform bless a manifest the cluster
            # refuses.
            if not version.get("served", True):
                continue

            target = out_dir / group / f"{kind.lower()}_{version['name']}.json"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps(schema_for(doc, version), indent=2) + "\n")
            written += 1

    if written == 0:
        print("error: no CustomResourceDefinitions found on stdin", file=sys.stderr)
        return 1

    print(f"gen-schemas: wrote {written} CRD schema(s) to {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
