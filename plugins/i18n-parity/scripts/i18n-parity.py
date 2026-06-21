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


# ---------- checks ----------


def scope_label(cid, ns):
    return "%s/%s" % (cid, ns) if ns else cid


def is_blank(v):
    return isinstance(v, str) and v.strip() == ""


def run_checks(config, ns_by_cat, loaded):
    """Run all parity checks. Return a list of (check, scope, key, locales, detail)."""
    locales = config["locales"]
    waivers = config.get("waivers", {}) or {}
    lok = waivers.get("localeOnlyKeys", {}) or {}
    ea = waivers.get("emptyAllowed", {}) or {}
    dps = waivers.get("directionPrefixes", []) or []
    out = []

    groups = defaultdict(dict)  # (cid, ns) -> {locale: cell|None}
    for (cid, ns, loc), cell in loaded.items():
        groups[(cid, ns)][loc] = cell

    # Waiver usage is tracked DURING the per-namespace pass below — never
    # reconstructed from a global key union, which would be wrong for
    # multi-namespace catalogs (the same dotted key can live in two namespaces,
    # so a union view could falsely mark a genuinely-used waiver stale).
    used_lok = set()   # (owner, key) suppressed at least one missing-key
    used_ea = set()    # (locale, key) suppressed at least one empty-value
    used_dp = set()    # indices of directionPrefixes rules that suppressed something

    def dp_waives(key, present, absent):
        """True if any directionPrefixes rule waives key for present->absent;
        marks every matching rule used."""
        hit = False
        for i, d in enumerate(dps):
            if d["present"] == present and absent in d["absentIn"] and \
                    any(key.startswith(p) for p in d["prefixes"]):
                used_dp.add(i)
                hit = True
        return hit

    for cid in sorted(ns_by_cat):
        for ns in sorted(ns_by_cat[cid]):
            scope = scope_label(cid, ns)
            byloc = groups.get((cid, ns), {})
            present_locales = [l for l in locales if byloc.get(l) is not None]
            missing_locales = [l for l in locales if byloc.get(l) is None]
            if present_locales and missing_locales:
                for ml in missing_locales:
                    out.append(("missing-namespace", scope, "", [ml],
                                "present for %s, missing for %s"
                                % (",".join(present_locales), ml)))
            if not present_locales:
                continue
            flats = {l: byloc[l]["flat"] for l in present_locales}
            for l in present_locales:
                for dk in byloc[l]["dups"]:
                    out.append(("duplicate-key", scope, dk, [l],
                                "declared more than once"))
            # presence parity — ordered pairs. Evaluate BOTH waiver kinds so each
            # that applies is marked used (do not short-circuit one behind the other).
            for a in present_locales:
                for b in present_locales:
                    if a == b:
                        continue
                    for key in flats[a]:
                        if key in flats[b]:
                            continue
                        waived = False
                        if key in lok.get(a, []):
                            used_lok.add((a, key))
                            waived = True
                        if dp_waives(key, a, b):
                            waived = True
                        if waived:
                            continue
                        out.append(("missing-key", scope, key, [b],
                                    "present in %s, missing in %s" % (a, b)))
            # per-key checks over the union
            allkeys = set()
            for l in present_locales:
                allkeys.update(flats[l])
            for key in allkeys:
                holders = [l for l in present_locales if key in flats[l]]
                for l in holders:
                    if is_blank(flats[l][key]["value"]):
                        if key in ea.get(l, []):
                            used_ea.add((l, key))
                        else:
                            out.append(("empty-value", scope, key, [l], "value is empty"))
                if len(holders) < 2:
                    continue
                if len(set(flats[l][key]["shape"] for l in holders)) > 1:
                    detail = ", ".join("%s=%s" % (l, flats[l][key]["shape"]) for l in holders)
                    out.append(("shape-mismatch", scope, key, list(holders), detail))
                if len(set(flats[l][key]["icu"] for l in holders)) > 1:
                    detail = ", ".join(
                        "%s={%s}" % (l, ",".join(sorted(flats[l][key]["icu"]))) for l in holders)
                    out.append(("icu-arg-mismatch", scope, key, list(holders), detail))

    # stale waivers — a waiver that suppressed nothing live fails loudly.
    for owner in sorted(lok):
        for k in lok[owner]:
            if (owner, k) not in used_lok:
                out.append(("stale-waiver", "localeOnlyKeys", k, [owner],
                            "suppressed no live missing-key "
                            "(key absent in owner, or present in every locale)"))
    for owner in sorted(ea):
        for k in ea[owner]:
            if (owner, k) not in used_ea:
                out.append(("stale-waiver", "emptyAllowed", k, [owner],
                            "no actually-empty key matched in locale"))
    for i, d in enumerate(dps):
        if i not in used_dp:
            out.append(("stale-waiver", "directionPrefixes", ",".join(d["prefixes"]),
                        [d["present"]], "suppressed no live divergence under prefixes"))
    return out
