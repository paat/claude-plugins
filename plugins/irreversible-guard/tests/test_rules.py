import json, os, re, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RULES_PATH = os.path.join(ROOT, "rules", "deny-set.json")


class TestRules(unittest.TestCase):
    def setUp(self):
        with open(RULES_PATH) as f:
            self.rules = json.load(f)

    def test_required_keys_present_and_lists(self):
        for k in ("tier1_regex", "tier2_regex", "warn_regex", "prod_markers",
                  "allow", "extra_block", "warn_only"):
            self.assertIn(k, self.rules)
            self.assertIsInstance(self.rules[k], list)

    def test_all_regexes_compile(self):
        for k in ("tier1_regex", "tier2_regex", "warn_regex"):
            for pat in self.rules[k]:
                re.compile(pat)  # raises if invalid

    def test_seeds_present(self):
        t1 = " ".join(self.rules["tier1_regex"])
        self.assertIn("destroy", t1)
        t2 = " ".join(self.rules["tier2_regex"])
        self.assertIn("DROP", t2)


if __name__ == "__main__":
    unittest.main()
