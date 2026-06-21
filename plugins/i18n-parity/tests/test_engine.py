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


if __name__ == "__main__":
    unittest.main()
