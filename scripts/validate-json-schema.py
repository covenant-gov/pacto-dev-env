#!/usr/bin/env python3
"""Dependency-free JSON Schema (draft 2020-12 subset) interpreter.

Supports exactly the keywords used by schemas/world-state.schema.json and
schemas/secrets-sidecar.schema.json: type, required, properties,
additionalProperties, items, minItems, minLength, minimum, enum, const,
pattern, and $ref restricted to local "#/$defs/<name>". Annotation-only
keywords (description, title, $schema, $id, ...) are ignored. Any other
keyword found in a schema is a loud failure rather than a silent pass, so
this interpreter cannot quietly under-check a future schema change.

Usage:
    scripts/validate-json-schema.py <schema.json> <instance.json>

Exit codes:
    0  instance is valid
    1  instance is invalid; one "<path>: <reason>" line per violation on stdout
    2  usage, I/O, parse, or unsupported-schema error (printed to stderr)
"""
import json
import re
import sys

SUPPORTED_KEYWORDS = {
    "type",
    "required",
    "properties",
    "additionalProperties",
    "items",
    "minItems",
    "minLength",
    "minimum",
    "enum",
    "const",
    "pattern",
    "$ref",
    "$defs",  # container for ref targets; never asserted against an instance
}
IGNORABLE_ANNOTATIONS = {
    "description",
    "title",
    "$schema",
    "$id",
    "default",
    "examples",
    "$comment",
    "deprecated",
    "readOnly",
    "writeOnly",
}


class SchemaError(Exception):
    """The schema itself is malformed, or uses an unsupported keyword/$ref."""


def _is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _type_name(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return type(value).__name__


def _matches_type(type_name, instance):
    if type_name == "object":
        return isinstance(instance, dict)
    if type_name == "array":
        return isinstance(instance, list)
    if type_name == "string":
        return isinstance(instance, str)
    if type_name == "integer":
        return isinstance(instance, int) and not isinstance(instance, bool)
    if type_name == "number":
        return _is_number(instance)
    if type_name == "boolean":
        return isinstance(instance, bool)
    if type_name == "null":
        return instance is None
    raise SchemaError(f"unsupported value for 'type': {type_name!r}")


def _json_equal(a, b):
    """JSON-level equality: true/false never equal a number, per the spec."""
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if _is_number(a) and _is_number(b):
        return a == b
    return type(a) is type(b) and a == b


def _render(value):
    return json.dumps(value)


def _child(path, key):
    return f"{path}.{key}" if path else key


def _index(path, idx):
    return f"{path}[{idx}]"


class Validator:
    def __init__(self, root_schema):
        self.root = root_schema
        self.errors = []

    def validate(self, schema, instance, path, ref_stack=()):
        if not isinstance(schema, dict):
            raise SchemaError(f"schema at {path or '<root>'} is not an object")

        unknown = set(schema) - SUPPORTED_KEYWORDS - IGNORABLE_ANNOTATIONS
        if unknown:
            raise SchemaError(
                f"unsupported schema keyword(s) {sorted(unknown)} at "
                f"{path or '<root>'}"
            )

        if "$ref" in schema:
            name = self._resolve_ref_name(schema["$ref"], path)
            if name in ref_stack:
                chain = " -> ".join(ref_stack + (name,))
                raise SchemaError(f"cyclic $ref detected: {chain}")
            target = self.root.get("$defs", {}).get(name)
            if target is None:
                raise SchemaError(f"$ref target not found: {schema['$ref']}")
            self.validate(target, instance, path, ref_stack + (name,))

        if "type" in schema:
            types = schema["type"]
            types = types if isinstance(types, list) else [types]
            if not any(_matches_type(t, instance) for t in types):
                self.errors.append(
                    (path, f"expected type {schema['type']}, got {_type_name(instance)}")
                )

        if "const" in schema and not _json_equal(schema["const"], instance):
            self.errors.append(
                (path, f"expected const {_render(schema['const'])}, got {_render(instance)}")
            )

        if "enum" in schema and not any(
            _json_equal(v, instance) for v in schema["enum"]
        ):
            self.errors.append(
                (path, f"expected one of {_render(schema['enum'])}, got {_render(instance)}")
            )

        if "pattern" in schema and isinstance(instance, str):
            if re.search(schema["pattern"], instance) is None:
                self.errors.append(
                    (path, f"does not match pattern {schema['pattern']!r}: {instance!r}")
                )

        if "minLength" in schema and isinstance(instance, str):
            if len(instance) < schema["minLength"]:
                self.errors.append(
                    (path, f"length {len(instance)} is less than minLength {schema['minLength']}")
                )

        if "minimum" in schema and _is_number(instance):
            if instance < schema["minimum"]:
                self.errors.append(
                    (path, f"{instance} is less than minimum {schema['minimum']}")
                )

        if isinstance(instance, dict):
            for key in schema.get("required", []):
                if key not in instance:
                    self.errors.append((_child(path, key), "required property is missing"))

            properties = schema.get("properties", {})
            for key, subschema in properties.items():
                if key in instance:
                    self.validate(subschema, instance[key], _child(path, key), ref_stack)

            additional = schema.get("additionalProperties", True)
            if additional is not True:
                extra_keys = [k for k in instance if k not in properties]
                if additional is False:
                    for key in extra_keys:
                        self.errors.append(
                            (_child(path, key), "additionalProperties is false: unexpected property")
                        )
                elif isinstance(additional, dict):
                    for key in extra_keys:
                        self.validate(additional, instance[key], _child(path, key), ref_stack)
                else:
                    raise SchemaError(
                        f"additionalProperties at {path or '<root>'} must be a boolean or a schema"
                    )

        if isinstance(instance, list):
            if "minItems" in schema and len(instance) < schema["minItems"]:
                self.errors.append(
                    (path, f"has {len(instance)} items, less than minItems {schema['minItems']}")
                )
            if "items" in schema:
                item_schema = schema["items"]
                for idx, item in enumerate(instance):
                    self.validate(item_schema, item, _index(path, idx), ref_stack)

        return self.errors

    def _resolve_ref_name(self, ref, path):
        prefix = "#/$defs/"
        if not isinstance(ref, str) or not ref.startswith(prefix):
            raise SchemaError(
                f"unsupported $ref at {path or '<root>'}: {ref!r} "
                "(only local #/$defs/<name> refs are supported)"
            )
        name = ref[len(prefix):]
        if not name or "/" in name:
            raise SchemaError(f"unsupported $ref at {path or '<root>'}: {ref!r}")
        return name


def _load_json(label, file_path):
    try:
        with open(file_path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except OSError as exc:
        raise SchemaError(f"cannot read {label} {file_path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise SchemaError(f"cannot parse {label} {file_path} as JSON: {exc}") from exc


def main(argv):
    if len(argv) != 3:
        print(f"usage: {argv[0]} <schema.json> <instance.json>", file=sys.stderr)
        return 2

    schema_path, instance_path = argv[1], argv[2]
    try:
        schema = _load_json("schema", schema_path)
        instance = _load_json("instance", instance_path)
        if not isinstance(schema, dict):
            raise SchemaError(f"root schema in {schema_path} is not a JSON object")
        validator = Validator(schema)
        errors = validator.validate(schema, instance, "")
    except SchemaError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if errors:
        for path, message in errors:
            print(f"{path if path else '<root>'}: {message}")
        return 1

    print(f"ok: {instance_path} is valid against {schema_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
