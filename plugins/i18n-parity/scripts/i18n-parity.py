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
