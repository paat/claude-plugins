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


class TestRunChecks(unittest.TestCase):
    def _leaf(self, value):
        icu = ip.extract_icu_args(value) if isinstance(value, str) else set()
        shape = "null" if value is None else "array" if isinstance(value, list) else "scalar"
        return {"shape": shape, "value": value, "icu": frozenset(icu)}

    def _cell(self, mapping, dups=None):
        return {"flat": {k: self._leaf(v) for k, v in mapping.items()}, "dups": dups or []}

    def _run(self, locales, cells, waivers=None, cid="c", namespaces=None):
        config = {"primaryLocale": locales[0], "locales": locales,
                  "catalogs": [{"pattern": "x/{locale}.json"}]}
        if waivers:
            config["waivers"] = waivers
        ns_by_cat = {cid: set(namespaces or [""])}
        loaded = {}
        for (ns, loc), cell in cells.items():
            loaded[(cid, ns, loc)] = cell
        return [v[0] for v in ip.run_checks(config, ns_by_cat, loaded)], \
               ip.run_checks(config, ns_by_cat, loaded)

    def test_balanced_passes(self):
        cells = {("", "et"): self._cell({"a": "x"}), ("", "en"): self._cell({"a": "y"})}
        kinds, _ = self._run(["et", "en"], cells)
        self.assertEqual(kinds, [])

    def test_missing_key_flagged(self):
        cells = {("", "et"): self._cell({"a": "x", "b": "z"}),
                 ("", "en"): self._cell({"a": "y"})}
        kinds, full = self._run(["et", "en"], cells)
        self.assertIn("missing-key", kinds)
        self.assertTrue(any(v[2] == "b" and v[3] == ["en"] for v in full if v[0] == "missing-key"))

    def test_missing_key_waived_by_locale_only(self):
        cells = {("", "et"): self._cell({"a": "x", "b": "z"}),
                 ("", "en"): self._cell({"a": "y"})}
        kinds, _ = self._run(["et", "en"], cells,
                             waivers={"localeOnlyKeys": {"et": ["b"]}})
        self.assertEqual(kinds, [])

    def test_empty_value_flagged_and_waivable(self):
        cells = {("", "et"): self._cell({"a": "x"}), ("", "en"): self._cell({"a": "  "})}
        kinds, _ = self._run(["et", "en"], cells)
        self.assertIn("empty-value", kinds)
        kinds2, _ = self._run(["et", "en"], cells,
                              waivers={"emptyAllowed": {"en": ["a"]}})
        self.assertEqual(kinds2, [])

    def test_icu_arg_mismatch(self):
        cells = {("", "et"): self._cell({"a": "hi {count}"}),
                 ("", "en"): self._cell({"a": "hi there"})}
        kinds, _ = self._run(["et", "en"], cells)
        self.assertIn("icu-arg-mismatch", kinds)

    def test_shape_mismatch(self):
        cells = {("", "et"): self._cell({"a": ["x"]}), ("", "en"): self._cell({"a": "y"})}
        kinds, _ = self._run(["et", "en"], cells)
        self.assertIn("shape-mismatch", kinds)

    def test_missing_namespace_single_violation(self):
        cells = {("common", "et"): self._cell({"a": "x"}),
                 ("common", "en"): self._cell({"a": "y"}),
                 ("admin", "et"): self._cell({"b": "x"}),
                 ("admin", "en"): None}
        config = {"primaryLocale": "et", "locales": ["et", "en"],
                  "catalogs": [{"pattern": "x/{locale}/{namespace}.json"}]}
        loaded = {("c", ns, loc): cell for (ns, loc), cell in cells.items()}
        full = ip.run_checks(config, {"c": {"common", "admin"}}, loaded)
        mn = [v for v in full if v[0] == "missing-namespace"]
        self.assertEqual(len(mn), 1)
        self.assertEqual(mn[0][3], ["en"])

    def test_duplicate_key_surfaced(self):
        cells = {("", "et"): self._cell({"a": "x"}, dups=["a"]),
                 ("", "en"): self._cell({"a": "y"})}
        kinds, _ = self._run(["et", "en"], cells)
        self.assertIn("duplicate-key", kinds)

    def test_stale_locale_only_waiver(self):
        cells = {("", "et"): self._cell({"a": "x"}), ("", "en"): self._cell({"a": "y"})}
        kinds, full = self._run(["et", "en"], cells,
                                waivers={"localeOnlyKeys": {"et": ["ghost"]}})
        self.assertIn("stale-waiver", kinds)

    def test_direction_prefix_waiver_and_stale(self):
        cells = {("", "ru"): self._cell({"only.ru.x": "z", "a": "r"}),
                 ("", "en"): self._cell({"a": "e"})}
        # ru-only key under waived prefix -> no missing-key
        kinds, _ = self._run(["ru", "en"], cells, waivers={"directionPrefixes": [
            {"present": "ru", "absentIn": ["en"], "prefixes": ["only.ru."]}]})
        self.assertNotIn("missing-key", kinds)
        # a prefix matching nothing live -> stale
        kinds2, _ = self._run(["ru", "en"], cells, waivers={"directionPrefixes": [
            {"present": "ru", "absentIn": ["en"], "prefixes": ["dead.prefix."]}]})
        self.assertIn("stale-waiver", kinds2)

    def test_stale_locale_only_when_present_everywhere(self):
        # 'a' exists in BOTH locales, so a localeOnlyKeys waiver protects nothing.
        cells = {("", "et"): self._cell({"a": "x"}), ("", "en"): self._cell({"a": "y"})}
        kinds, _ = self._run(["et", "en"], cells,
                             waivers={"localeOnlyKeys": {"et": ["a"]}})
        self.assertIn("stale-waiver", kinds)

    def test_stale_direction_prefix_when_present_in_all(self):
        # prefix present in BOTH locales -> no real divergence -> stale.
        cells = {("", "ru"): self._cell({"only.ru.x": "z"}),
                 ("", "en"): self._cell({"only.ru.x": "z"})}
        kinds, _ = self._run(["ru", "en"], cells, waivers={"directionPrefixes": [
            {"present": "ru", "absentIn": ["en"], "prefixes": ["only.ru."]}]})
        self.assertIn("stale-waiver", kinds)

    def test_locale_only_waiver_is_namespace_scoped(self):
        # 'x' exists in both locales under 'common', but only in 'et' under 'admin'.
        # A localeOnlyKeys et:['x'] waiver suppresses the real admin missing-key and
        # must NOT be marked stale by a cross-namespace union (the original bug).
        cells = {
            ("common", "et"): self._cell({"x": "a"}),
            ("common", "en"): self._cell({"x": "b"}),
            ("admin", "et"): self._cell({"x": "c"}),
            ("admin", "en"): self._cell({"y": "d"}),
        }
        kinds, full = self._run(["et", "en"], cells,
                                waivers={"localeOnlyKeys": {"et": ["x"]}},
                                namespaces=["common", "admin"])
        self.assertNotIn("stale-waiver", kinds)
        self.assertFalse(any(v[0] == "missing-key" and v[2] == "x" for v in full))


class TestCli(unittest.TestCase):
    def _repo(self, d, cfg, files):
        with open(os.path.join(d, ".i18n-parity.json"), "w", encoding="utf-8") as f:
            json.dump(cfg, f)
        for rel, obj in files.items():
            p = os.path.join(d, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8") as fh:
                json.dump(obj, fh)

    def test_clean_exit_zero(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = {"primaryLocale": "et", "locales": ["et", "en"],
                   "catalogs": [{"pattern": "messages/{locale}.json"}]}
            self._repo(d, cfg, {"messages/et.json": {"a": "x"},
                                "messages/en.json": {"a": "y"}})
            rc = ip.main(["--config", os.path.join(d, ".i18n-parity.json"), "--root", d])
            self.assertEqual(rc, 0)

    def test_violation_exit_one(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = {"primaryLocale": "et", "locales": ["et", "en"],
                   "catalogs": [{"pattern": "messages/{locale}.json"}]}
            self._repo(d, cfg, {"messages/et.json": {"a": "x", "b": "z"},
                                "messages/en.json": {"a": "y"}})
            rc = ip.main(["--config", os.path.join(d, ".i18n-parity.json"), "--root", d])
            self.assertEqual(rc, 1)

    def test_config_error_exit_two(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = {"primaryLocale": "et", "locales": ["et"],
                   "catalogs": [{"pattern": "messages/{locale}.json"}], "bogus": 1}
            self._repo(d, cfg, {})
            rc = ip.main(["--config", os.path.join(d, ".i18n-parity.json"), "--root", d])
            self.assertEqual(rc, 2)

    def test_invalid_json_exit_two(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = {"primaryLocale": "et", "locales": ["et"],
                   "catalogs": [{"pattern": "messages/{locale}.json"}]}
            self._repo(d, cfg, {})
            p = os.path.join(d, "messages")
            os.makedirs(p, exist_ok=True)
            with open(os.path.join(p, "et.json"), "w", encoding="utf-8") as f:
                f.write("{bad")
            rc = ip.main(["--config", os.path.join(d, ".i18n-parity.json"), "--root", d])
            self.assertEqual(rc, 2)

    def test_json_output_is_valid(self):
        import io, contextlib
        with tempfile.TemporaryDirectory() as d:
            cfg = {"primaryLocale": "et", "locales": ["et", "en"],
                   "catalogs": [{"pattern": "messages/{locale}.json"}]}
            self._repo(d, cfg, {"messages/et.json": {"a": "x", "b": "z"},
                                "messages/en.json": {"a": "y"}})
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                ip.main(["--config", os.path.join(d, ".i18n-parity.json"),
                         "--root", d, "--json"])
            parsed = json.loads(buf.getvalue())
            self.assertTrue(any(v["check"] == "missing-key" for v in parsed))


class TestUnreadableInputs(unittest.TestCase):
    """Regression: PermissionError/IsADirectoryError must route to exit 2, not crash."""

    def test_directory_as_config_path_exits_two(self):
        # Opening a directory raises IsADirectoryError (an OSError), not FileNotFoundError.
        # Before the fix this escaped as a traceback (exit 1); must now be exit 2.
        with tempfile.TemporaryDirectory() as d:
            # Use d itself as the config path — it is a directory, not a file.
            rc = ip.main(["--config", d, "--root", d])
            self.assertEqual(rc, 2)

    def test_load_catalog_directory_routes_invalid_json(self):
        # Directly call load_catalog with a directory path.
        # Opening a directory raises IsADirectoryError (OSError but NOT FileNotFoundError).
        # Before the fix: uncaught traceback. After fix: (None, ("invalid-json", ...)).
        with tempfile.TemporaryDirectory() as d:
            dir_path = os.path.join(d, "catalog_dir")
            os.makedirs(dir_path)
            data, err = ip.load_catalog(dir_path)
            self.assertIsNone(data)
            self.assertIsNotNone(err)
            self.assertEqual(err[0], "invalid-json")
            self.assertIn(dir_path, err[1])

    def test_load_catalog_missing_file_still_routes_missing_file(self):
        # FileNotFoundError must still route to "missing-file" (regression guard).
        data, err = ip.load_catalog("/nonexistent/path/catalog.json")
        self.assertIsNone(data)
        self.assertIsNotNone(err)
        self.assertEqual(err[0], "missing-file")


if __name__ == "__main__":
    unittest.main()
