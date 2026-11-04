#!/usr/bin/env python3
"""Converts hass-xiaomi-miot's legacy miIO → MIoT tables into the JSON MijiaLAN bundles.

    REV=<commit>
    mkdir -p /tmp/hxm && curl -sfL -o /tmp/hxm/miio2miot_specs.py \\
      https://raw.githubusercontent.com/al-one/hass-xiaomi-miot/$REV/custom_components/xiaomi_miot/core/miio2miot_specs.py
    python3 -I scripts/import_hass_xiaomi_miot.py /tmp/hxm/miio2miot_specs.py $REV

The source file is only parsed (`ast`), never imported or run. Every property keeps hass-xiaomi-miot's meaning
(see `Miio2MiotHelper` in its `core/miio2miot.py`): a read applies the template, else the `onoff` format, else the
value table, else the MIoT format; a write applies `set_template`, else the format, else the reverse table, else
sends the value. Jinja templates have no Swift counterpart, so the common ones are translated into declarative
transforms below; a property whose template is not in these tables is left out with the reason recorded.

Output: Sources/MijiaLAN/Resources/hass-xiaomi-miot-miio2miot.json (Apache-2.0, see THIRD_PARTY_NOTICES.md).
"""
import ast
import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Sources/MijiaLAN/Resources/hass-xiaomi-miot-miio2miot.json"


def squeeze(template: str) -> str:
    return re.sub(r"\s+", "", template)


# Read templates → transform. `value` is what `get_prop` returned for the property.
READ_TEMPLATES = {
    "{{value!=0}}": {"kind": "nonZero"},
    "{{value|int(0)>0}}": {"kind": "nonZero"},
    "{{value|int>0}}": {"kind": "nonZero"},
    "{{value|default(0,true)/10.0}}": {"kind": "number", "ratio": 0.1},
    "{{value/10.0}}": {"kind": "number", "ratio": 0.1},
    "{{value|int+1}}": {"kind": "number", "offset": 1},
    "{{value|int-1}}": {"kind": "number", "offset": -1},
    "{{value|int-100}}": {"kind": "number", "offset": -100},
    "{{value|int(0)}}": {"kind": "number"},
    "{{value|int}}": {"kind": "number"},
    "{{value|float}}": {"kind": "number"},
    '{{value|regex_replace("rpm","")|int}}': {"kind": "number", "strip": "rpm"},
    '{{value!="off"}}': {"kind": "notEquals", "value": "off"},
    '{{value=="on"}}': {"kind": "equals", "value": "on"},
    '{{valuein["swing"]}}': {"kind": "equals", "value": "swing"},
    '{{valuein["coolwind"]}}': {"kind": "equals", "value": "coolwind"},
    '{{0ifvaluein["off"]else180}}': {"kind": "ifEquals", "value": "off", "then": 0, "else": 180},
    "{{2ifvalue==0else1}}": {"kind": "ifEquals", "value": 0, "then": 2, "else": 1},
    "{{1ifvalue==6else0}}": {"kind": "ifEquals", "value": 6, "then": 1, "else": 0},
    "{{2ifvalue|intelse1}}": {"kind": "ifNonZero", "then": 2, "else": 1},
    "{{1ifvalue|int(0)>0else0}}": {"kind": "ifNonZero", "then": 1, "else": 0},
}

# Write templates → transform. The result is the setter's parameter list; a bare value becomes a one-item list.
WRITE_TEMPLATES = {
    "{{[value|int]}}": {"kind": "integer"},
    "{{[value|int(0)]}}": {"kind": "integer"},
    "{{[value|int(1)]}}": {"kind": "integer"},
    "{{[value|int-1]}}": {"kind": "integer", "offset": -1},
    "{{[value|int(0)*25]}}": {"kind": "integer", "ratio": 25},
    "{{(value*10)|int(0)}}": {"kind": "integer", "ratio": 10},
    "{{[value]}}": {"kind": "value"},
    "{{[value|string]}}": {"kind": "string"},
    '{{[value,"smooth",500]}}': {"kind": "value", "suffix": ["smooth", 500]},
    '{{["on"ifvalueelse"off"]}}': {"kind": "onOff"},
    '{{["on"ifvalueelse"off","smooth",500]}}': {"kind": "onOff", "suffix": ["smooth", 500]},
    "{{[1ifvalueelse0]}}": {"kind": "boolChoice", "on": 1, "off": 0},
    "{{[100ifvalueelse0]}}": {"kind": "boolChoice", "on": 100, "off": 0},
    "{{[5ifvalueelse0]}}": {"kind": "boolChoice", "on": 5, "off": 0},
    '{{["swing"ifvalueelse"stop"]}}': {"kind": "boolChoice", "on": "swing", "off": "stop"},
    '{{{"method":"set_usb_on"ifvalueelse"set_usb_off"}}}': {"kind": "methodSwitch", "on": "set_usb_on", "off": "set_usb_off"},
    '{{{"method":"set_on"ifvalueelse"set_off"}}}': {"kind": "methodSwitch", "on": "set_on", "off": "set_off"},
}


def literal(node):
    try:
        return ast.literal_eval(node)
    except (ValueError, SyntaxError, TypeError):
        return None


def entry_dict(node: ast.Dict) -> dict:
    """A table entry with every literal value; non-literal ones (lambdas, class references) are dropped."""
    out = {}
    for key, value in zip(node.keys, node.values):
        name = literal(key) if key is not None else None
        if not isinstance(name, str):
            continue
        if name == "miio_specs" and isinstance(value, ast.Dict):
            specs = {}
            for pk, pv in zip(value.keys, value.values):
                pname = literal(pk) if pk is not None else None
                if isinstance(pname, str) and isinstance(pv, ast.Dict):
                    prop = {}
                    for fk, fv in zip(pv.keys, pv.values):
                        fname = literal(fk) if fk is not None else None
                        if isinstance(fname, str):
                            prop[fname] = literal(fv) if fname != "set_callback" else "<callback>"
                    specs[pname] = prop
            out[name] = specs
        else:
            out[name] = literal(value)
    return out


def load_table(path: Path) -> dict:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    for node in tree.body:
        target = node.targets[0] if isinstance(node, ast.Assign) else getattr(node, "target", None)
        if isinstance(target, ast.Name) and target.id == "MIIO_TO_MIOT_SPECS" and isinstance(node.value, ast.Dict):
            table = {}
            for key, value in zip(node.value.keys, node.value.values):
                model = literal(key)
                if isinstance(value, ast.Dict):
                    table[model] = entry_dict(value)
                elif isinstance(literal(value), str):
                    table[model] = literal(value)
            return table
    raise SystemExit("MIIO_TO_MIOT_SPECS not found")


def resolve(table: dict, model: str, seen=()) -> tuple[dict, str]:
    """The merged entry for `model` and the table entry it comes from (aliases and `extend_model` followed)."""
    if model in seen:
        raise SystemExit(f"alias loop at {model}")
    entry = table.get(model)
    if isinstance(entry, str):
        return resolve(table, entry, seen + (model,))
    if not isinstance(entry, dict):
        return {}, model
    base = entry.get("extend_model")
    if base:
        parent, _ = resolve(table, base, seen + (model,))
        specs = {**parent.get("miio_specs", {}), **entry.get("miio_specs", {})}
        entry = {**parent, **entry, "miio_specs": specs}
    return entry, model


def convert_property(key: str, spec: dict, command_props: set) -> tuple[dict | None, str | None]:
    match = re.fullmatch(r"prop\.(\d+)\.(\d+)", key)
    if not match:
        return None, "action" if key.startswith("action.") else f"unknown key {key}"
    name = spec.get("prop")
    if not isinstance(name, str) or not name:
        return None, "value derived from other properties"
    if name in command_props:
        return None, "value comes from a miio command"
    if spec.get("set_callback"):
        return None, "write has a callback"
    out = {"siid": int(match[1]), "piid": int(match[2]), "name": name}

    table = spec.get("dict")
    fmt = spec.get("format")
    if spec.get("template") is not None:
        read = READ_TEMPLATES.get(squeeze(str(spec["template"])))
        if read is None:
            return None, f"read template {squeeze(str(spec['template']))}"
    elif fmt == "onoff":
        read = {"kind": "onOff"}
    elif fmt == "rgb":
        read = {"kind": "number"}
    elif isinstance(table, dict) and table:
        read = {"kind": "values", "table": {str(k): v for k, v in table.items()}}
        if "default" in spec:
            read["default"] = spec["default"]
    elif spec.get("value_ratio"):
        read = {"kind": "number", "ratio": float(spec["value_ratio"])}
    else:
        read = {"kind": "auto"}
    out["read"] = read

    setter = spec.get("setter")
    if setter:
        method = f"set_{name}" if setter is True else str(setter)
        if spec.get("set_template") is not None:
            write = WRITE_TEMPLATES.get(squeeze(str(spec["set_template"])))
            if write is None:
                out["writeSkipped"] = f"write template {squeeze(str(spec['set_template']))}"
        elif fmt == "onoff":
            write = {"kind": "onOff"}
        elif fmt == "rgb":
            write = {"kind": "value"}
        elif isinstance(table, dict) and table:
            write = {"kind": "values", "table": {str(k): v for k, v in table.items()}}
        else:
            write = {"kind": "value"}
        if spec.get("set_template") is None or write is not None:
            out["write"] = {"method": method, **write}
    return out, None


def convert(table: dict) -> tuple[dict, Counter]:
    stats = Counter()
    models = {}
    for model in sorted(table):
        if model.endswith("._base"):
            continue  # shared bases for `extend_model`, not real models
        entry, source = resolve(table, model)
        specs = entry.get("miio_specs") or {}
        if not specs:
            stats["models without property tables"] += 1
            continue
        if entry.get("without_props") or entry.get("miio_template"):
            stats["models read only through miio commands"] += 1
            continue
        commands = entry.get("miio_commands") or []
        if any(not isinstance(c, dict) or c.get("template") for c in commands):
            stats["models read through command templates"] += 1
            continue
        # `values: True` names the results after the command's own params.
        command_props = {
            v for c in commands
            for v in ((c.get("params") if c.get("values") is True else c.get("values")) or [])
            if isinstance(v, str)
        }

        properties, skipped = [], []
        for key in sorted(specs, key=lambda k: [int(x) if x.isdigit() else x for x in k.split(".")]):
            prop, reason = convert_property(key, specs[key] or {}, command_props)
            if prop is None:
                skipped.append({"key": key, "reason": reason})
                stats[f"skipped: {reason.split(' ')[0] if reason.startswith(('read', 'write')) else reason}"] += 1
                continue
            if "writeSkipped" in prop:
                skipped.append({"key": key, "reason": prop.pop("writeSkipped")})
                stats["read only: write template"] += 1
            properties.append(prop)
            stats["properties"] += 1
        if not properties:
            stats["models with no convertible property"] += 1
            continue
        out = {"properties": properties}
        resolved_from = table.get(model)
        if isinstance(resolved_from, str):
            out["base"] = source if source != model else resolved_from
        if isinstance(entry.get("chunk_properties"), int):
            out["chunk"] = entry["chunk_properties"]
        if entry.get("ignore_result"):
            out["ignoreResult"] = True
        if skipped:
            out["skipped"] = skipped
        models[model] = out
        stats["models"] += 1
    return models, stats


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    source, revision = Path(sys.argv[1]), sys.argv[2]
    models, stats = convert(load_table(source))
    document = {
        "source": "https://github.com/al-one/hass-xiaomi-miot",
        "file": "custom_components/xiaomi_miot/core/miio2miot_specs.py",
        "revision": revision,
        "license": "Apache-2.0",
        "note": "Generated by scripts/import_hass_xiaomi_miot.py; converted from the Python table, do not edit by hand.",
        "models": models,
    }
    OUTPUT.write_text(json.dumps(document, ensure_ascii=False, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    for key, count in sorted(stats.items(), key=lambda item: (-item[1], item[0])):
        print(f"{count:5}  {key}")
    print(f"wrote {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
