#!/usr/bin/env python3
"""i18n-parity — translation key-parity gate. Stdlib-only, vendorable.

Exit codes: 0 = clean, 1 = parity violations, 2 = config/usage error.
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys
from collections import defaultdict

CONFIG_NAME = ".i18n-parity.json"

_ALLOWED_TOP = {"primaryLocale", "locales", "catalogs", "waivers"}
_ALLOWED_CATALOG = {"id", "pattern"}
_ALLOWED_WAIVERS = {"localeOnlyKeys", "emptyAllowed", "directionPrefixes"}
_ALLOWED_DIRPREFIX = {"present", "absentIn", "prefixes"}


class ConfigError(Exception):
    """A config or usage problem -> exit 2."""


def _is_str_list(x):
    return isinstance(x, list) and all(isinstance(i, str) for i in x)


def _validate_keymap(name, val):
    if not isinstance(val, dict) or not all(
        isinstance(k, str) and _is_str_list(v) for k, v in val.items()
    ):
        raise ConfigError("%s must map locale -> array of key strings" % name)


def load_config(path):
    """Load + strictly validate the config. Raise ConfigError on any problem."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            raw = json.load(f)
    except FileNotFoundError:
        raise ConfigError("config not found: %s" % path)
    except json.JSONDecodeError as e:
        raise ConfigError("config is not valid JSON (%s): %s" % (path, e))
    if not isinstance(raw, dict):
        raise ConfigError("config root must be a JSON object")

    unknown = set(raw) - _ALLOWED_TOP
    if unknown:
        raise ConfigError("unknown config field(s): %s" % ", ".join(sorted(unknown)))
    for req in ("primaryLocale", "locales", "catalogs"):
        if req not in raw:
            raise ConfigError("missing required config field: %s" % req)

    if not _is_str_list(raw["locales"]) or not raw["locales"]:
        raise ConfigError("locales must be a non-empty array of strings")
    if not isinstance(raw["primaryLocale"], str):
        raise ConfigError("primaryLocale must be a string")
    if raw["primaryLocale"] not in raw["locales"]:
        raise ConfigError("primaryLocale must be one of locales")

    if not isinstance(raw["catalogs"], list) or not raw["catalogs"]:
        raise ConfigError("catalogs must be a non-empty array")
    for c in raw["catalogs"]:
        if not isinstance(c, dict):
            raise ConfigError("each catalog must be an object")
        cu = set(c) - _ALLOWED_CATALOG
        if cu:
            raise ConfigError("unknown catalog field(s): %s" % ", ".join(sorted(cu)))
        if "pattern" not in c or not isinstance(c["pattern"], str):
            raise ConfigError("each catalog needs a string 'pattern'")
        if "{locale}" not in c["pattern"]:
            raise ConfigError("catalog pattern must contain {locale}: %s" % c["pattern"])
        if "id" in c and not isinstance(c["id"], str):
            raise ConfigError("catalog 'id' must be a string")

    waivers = raw.get("waivers", {})
    if not isinstance(waivers, dict):
        raise ConfigError("waivers must be an object")
    wu = set(waivers) - _ALLOWED_WAIVERS
    if wu:
        raise ConfigError("unknown waiver field(s): %s" % ", ".join(sorted(wu)))
    _validate_keymap("localeOnlyKeys", waivers.get("localeOnlyKeys", {}))
    _validate_keymap("emptyAllowed", waivers.get("emptyAllowed", {}))
    dps = waivers.get("directionPrefixes", [])
    if not isinstance(dps, list):
        raise ConfigError("directionPrefixes must be an array")
    for d in dps:
        if not isinstance(d, dict) or (set(_ALLOWED_DIRPREFIX) - set(d)) or (set(d) - _ALLOWED_DIRPREFIX):
            raise ConfigError("each directionPrefixes entry needs exactly: present, absentIn, prefixes")
        if not isinstance(d["present"], str) or not _is_str_list(d["absentIn"]) or not _is_str_list(d["prefixes"]):
            raise ConfigError("directionPrefixes types: present=str, absentIn=[str], prefixes=[str]")
    return raw


# ---------- catalog parsing ----------

_ICU_ARG = re.compile(r"\{\s*([A-Za-z0-9_]+)")
_ICU_QUOTED = re.compile(r"'(?:''|[^'])*'")


def extract_icu_args(s):
    """Argument names in an ICU string. Deliberately limited grammar:
    first identifier after each '{', with apostrophe-quoted spans stripped
    best-effort. Branch categories (one/other/=0) are NOT parsed."""
    cleaned = _ICU_QUOTED.sub("", s)
    return set(_ICU_ARG.findall(cleaned))


_OBJ = "\x00obj"  # sentinel tag: object_pairs_hook wraps every JSON object so
                  # duplicate keys survive (a plain dict would collapse last-wins).


def _is_obj(x):
    return isinstance(x, tuple) and len(x) == 2 and x[0] is _OBJ


def _leaf(value):
    """Build a leaf record (shape/value/icu) for a non-object JSON value."""
    if value is None:
        shape = "null"
    elif isinstance(value, list):
        shape = "array"
    else:
        shape = "scalar"
    icu = extract_icu_args(value) if isinstance(value, str) else set()
    return {"shape": shape, "value": value, "icu": frozenset(icu)}


def flatten(obj, prefix=""):
    """Nested dict -> {dotted-path: leaf}. Objects recurse; arrays/null/scalars
    are opaque leaves (intra-array structure out of scope). For plain dicts."""
    out = {}
    if isinstance(obj, dict):
        for k, v in obj.items():
            key = "%s.%s" % (prefix, k) if prefix else k
            if isinstance(v, dict):
                out.update(flatten(v, key))
            else:
                out[key] = _leaf(v)
    return out


def _walk_pairs(node, prefix, flat, dups):
    """Walk a ('\x00obj', [(k, v), ...]) tree, filling flat (dotted leaf map)
    and dups (dotted paths declared more than once in the same object)."""
    seen = set()
    for k, v in node[1]:
        key = "%s.%s" % (prefix, k) if prefix else k
        if k in seen:
            dups.append(key)
        seen.add(k)
        if _is_obj(v):
            _walk_pairs(v, key, flat, dups)
        else:
            flat[key] = _leaf(v)


def load_catalog(path):
    """Return ({"flat":..., "dups":[dotted...]}, None) or (None, (kind, detail))."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            tree = json.load(f, object_pairs_hook=lambda pairs: (_OBJ, pairs))
    except FileNotFoundError:
        return None, ("missing-file", path)
    except json.JSONDecodeError as e:
        return None, ("invalid-json", "%s: %s" % (path, e))
    if not _is_obj(tree):
        return None, ("invalid-json", "%s: root is not a JSON object" % path)
    flat, dups = {}, []
    _walk_pairs(tree, "", flat, dups)
    return {"flat": flat, "dups": sorted(set(dups))}, None


# ---------- catalog resolution ----------


def derive_id(pattern):
    """Stable slug from a pattern's literal (non-placeholder) segments."""
    lit = pattern.replace("{locale}", "").replace("{namespace}", "")
    slug = re.sub(r"[^A-Za-z0-9]+", "-", lit).strip("-")
    return slug or "catalog"


def resolve_catalogs(config, root):
    """Build grid[(cid, ns, locale)] = abspath|None and ns_by_cat[cid] = set(ns).
    ns is "" for catalogs without {namespace}. Raise ConfigError on id collision
    or a catalog that matches zero files across all locales."""
    locales = config["locales"]
    grid = {}
    ns_by_cat = {}
    seen_ids = {}
    for c in config["catalogs"]:
        pattern = c["pattern"]
        cid = c.get("id") or derive_id(pattern)
        if cid in seen_ids:
            raise ConfigError(
                "catalog id collision: '%s' — give each catalog a unique 'id'" % cid)
        seen_ids[cid] = pattern
        has_ns = "{namespace}" in pattern
        namespaces = set()
        per_locale = {}  # locale -> {ns: abspath}
        for loc in locales:
            loc_pat = pattern.replace("{locale}", loc)
            files = {}
            if has_ns:
                glob_pat = os.path.join(root, loc_pat.replace("{namespace}", "*"))
                regex = re.compile(
                    "^" + re.escape(os.path.join(root, loc_pat)).replace(
                        re.escape("{namespace}"), "(.+)") + "$")
                for fp in glob.glob(glob_pat):
                    m = regex.match(fp)
                    if m:
                        ns = m.group(1)
                        files[ns] = fp
                        namespaces.add(ns)
            else:
                fp = os.path.join(root, loc_pat)
                if os.path.isfile(fp):
                    files[""] = fp
                    namespaces.add("")
            per_locale[loc] = files
        if not namespaces:
            raise ConfigError(
                "catalog '%s' matched zero files for pattern '%s'" % (cid, pattern))
        ns_by_cat[cid] = namespaces
        for loc in locales:
            for ns in namespaces:
                grid[(cid, ns, loc)] = per_locale[loc].get(ns)
    return grid, ns_by_cat


def load_all(grid):
    """Load every grid cell. Return (loaded, json_errors). A None path stays
    None (namespace/catalog-missing -> violation later). Invalid JSON -> error."""
    loaded = {}
    json_errors = []
    for key, path in grid.items():
        if path is None:
            loaded[key] = None
            continue
        data, err = load_catalog(path)
        if err is None:
            loaded[key] = data
        else:
            loaded[key] = None
            if err[0] == "invalid-json":
                json_errors.append(err[1])
    return loaded, json_errors
