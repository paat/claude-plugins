import importlib.util, os, json, tempfile, unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_ENGINE = os.path.join(_HERE, "..", "scripts", "i18n-parity.py")
_spec = importlib.util.spec_from_file_location("i18n_parity", _ENGINE)
ip = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ip)


def _write(d, name, obj):
    p = os.path.join(d, name)
    with open(p, "w", encoding="utf-8") as f:
        json.dump(obj, f)
    return p


class TestLoadConfig(unittest.TestCase):
    def _cfg(self, d, obj):
        return _write(d, ".i18n-parity.json", obj)

    def test_valid_config_roundtrips(self):
        with tempfile.TemporaryDirectory() as d:
            p = self._cfg(d, {
                "primaryLocale": "et",
                "locales": ["et", "en"],
                "catalogs": [{"pattern": "messages/{locale}.json"}],
            })
            cfg = ip.load_config(p)
            self.assertEqual(cfg["primaryLocale"], "et")

    def test_unknown_top_field_fails(self):
        with tempfile.TemporaryDirectory() as d:
            p = self._cfg(d, {
                "primaryLocale": "et", "locales": ["et"],
                "catalogs": [{"pattern": "{locale}.json"}],
                "bogus": 1,
            })
            with self.assertRaises(ip.ConfigError):
                ip.load_config(p)

    def test_unknown_waiver_field_fails(self):
        with tempfile.TemporaryDirectory() as d:
            p = self._cfg(d, {
                "primaryLocale": "et", "locales": ["et"],
                "catalogs": [{"pattern": "{locale}.json"}],
                "waivers": {"typoKeys": {}},
            })
            with self.assertRaises(ip.ConfigError):
                ip.load_config(p)

    def test_pattern_without_locale_fails(self):
        with tempfile.TemporaryDirectory() as d:
            p = self._cfg(d, {
                "primaryLocale": "et", "locales": ["et"],
                "catalogs": [{"pattern": "messages/all.json"}],
            })
            with self.assertRaises(ip.ConfigError):
                ip.load_config(p)

    def test_primary_not_in_locales_fails(self):
        with tempfile.TemporaryDirectory() as d:
            p = self._cfg(d, {
                "primaryLocale": "xx", "locales": ["et", "en"],
                "catalogs": [{"pattern": "{locale}.json"}],
            })
            with self.assertRaises(ip.ConfigError):
                ip.load_config(p)

    def test_missing_file_fails(self):
        with self.assertRaises(ip.ConfigError):
            ip.load_config("/nonexistent/.i18n-parity.json")


class TestIcuArgs(unittest.TestCase):
    def test_simple_arg(self):
        self.assertEqual(ip.extract_icu_args("Hello {name}!"), {"name"})

    def test_plural_arg_name_only(self):
        self.assertEqual(
            ip.extract_icu_args("{count, plural, one {# item} other {# items}}"),
            {"count"},
        )

    def test_quoted_brace_ignored(self):
        # ICU apostrophe-escaped literal brace must not count as an arg.
        self.assertEqual(ip.extract_icu_args("a '{' literal {x}"), {"x"})

    def test_no_args(self):
        self.assertEqual(ip.extract_icu_args("plain text"), set())


class TestFlatten(unittest.TestCase):
    def test_nested_paths_and_shapes(self):
        flat = ip.flatten({"a": {"b": "x"}, "c": [1, 2], "d": None, "e": 5})
        self.assertEqual(set(flat), {"a.b", "c", "d", "e"})
        self.assertEqual(flat["a.b"]["shape"], "scalar")
        self.assertEqual(flat["c"]["shape"], "array")
        self.assertEqual(flat["d"]["shape"], "null")
        self.assertEqual(flat["e"]["shape"], "scalar")

    def test_icu_captured_on_scalars(self):
        flat = ip.flatten({"greet": "Hi {name}"})
        self.assertEqual(flat["greet"]["icu"], frozenset({"name"}))


class TestLoadCatalog(unittest.TestCase):
    def test_loads_and_flattens(self):
        with tempfile.TemporaryDirectory() as d:
            p = _write(d, "et.json", {"a": {"b": "x"}})
            data, err = ip.load_catalog(p)
            self.assertIsNone(err)
            self.assertIn("a.b", data["flat"])
            self.assertEqual(data["dups"], [])

    def test_duplicate_key_detected(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "et.json")
            with open(p, "w", encoding="utf-8") as f:
                f.write('{"a": 1, "a": 2}')
            data, err = ip.load_catalog(p)
            self.assertIsNone(err)
            self.assertEqual(data["dups"], ["a"])

    def test_nested_duplicate_key_is_dotted(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "et.json")
            with open(p, "w", encoding="utf-8") as f:
                f.write('{"common": {"save": 1, "save": 2}}')
            data, err = ip.load_catalog(p)
            self.assertIsNone(err)
            self.assertEqual(data["dups"], ["common.save"])
            # the surviving (last-wins) value is still flattened under the dotted path
            self.assertIn("common.save", data["flat"])

    def test_invalid_json_returns_error(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "et.json")
            with open(p, "w", encoding="utf-8") as f:
                f.write("{not json")
            data, err = ip.load_catalog(p)
            self.assertIsNone(data)
            self.assertEqual(err[0], "invalid-json")

    def test_non_object_root_is_invalid(self):
        with tempfile.TemporaryDirectory() as d:
            p = _write(d, "et.json", [1, 2, 3])
            data, err = ip.load_catalog(p)
            self.assertIsNone(data)
            self.assertEqual(err[0], "invalid-json")


class TestResolveCatalogs(unittest.TestCase):
    def _mk(self, root, rel, obj):
        p = os.path.join(root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            json.dump(obj, f)
        return p

    def test_single_file_grid(self):
        with tempfile.TemporaryDirectory() as d:
            self._mk(d, "messages/et.json", {"a": "x"})
            self._mk(d, "messages/en.json", {"a": "y"})
            cfg = {"primaryLocale": "et", "locales": ["et", "en"],
                   "catalogs": [{"pattern": "messages/{locale}.json"}]}
            grid, ns = ip.resolve_catalogs(cfg, d)
            cid = ip.derive_id("messages/{locale}.json")
            self.assertEqual(ns[cid], {""})
            self.assertIsNotNone(grid[(cid, "", "et")])
            self.assertIsNotNone(grid[(cid, "", "en")])

    def test_namespaced_discovery(self):
        with tempfile.TemporaryDirectory() as d:
            self._mk(d, "loc/et/common.json", {"a": "x"})
            self._mk(d, "loc/et/admin.json", {"b": "x"})
            self._mk(d, "loc/en/common.json", {"a": "y"})
            cfg = {"primaryLocale": "et", "locales": ["et", "en"],
                   "catalogs": [{"id": "pkg", "pattern": "loc/{locale}/{namespace}.json"}]}
            grid, ns = ip.resolve_catalogs(cfg, d)
            self.assertEqual(ns["pkg"], {"common", "admin"})
            # admin missing for en -> grid cell is None (a violation later, not an error)
            self.assertIsNone(grid[("pkg", "admin", "en")])
            self.assertIsNotNone(grid[("pkg", "common", "en")])

    def test_zero_match_catalog_is_config_error(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = {"primaryLocale": "et", "locales": ["et"],
                   "catalogs": [{"pattern": "nowhere/{locale}.json"}]}
            with self.assertRaises(ip.ConfigError):
                ip.resolve_catalogs(cfg, d)

    def test_id_collision_is_config_error(self):
        with tempfile.TemporaryDirectory() as d:
            self._mk(d, "messages/et.json", {"a": "x"})
            cfg = {"primaryLocale": "et", "locales": ["et"],
                   "catalogs": [
                       {"id": "dup", "pattern": "messages/{locale}.json"},
                       {"id": "dup", "pattern": "messages/{locale}.json"},
                   ]}
            with self.assertRaises(ip.ConfigError):
                ip.resolve_catalogs(cfg, d)


class TestLoadAll(unittest.TestCase):
    def test_missing_cell_is_none_not_error(self):
        loaded, errs = ip.load_all({("c", "", "et"): None})
        self.assertIsNone(loaded[("c", "", "et")])
        self.assertEqual(errs, [])


if __name__ == "__main__":
    unittest.main()
