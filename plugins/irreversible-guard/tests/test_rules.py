import json, os, re, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RULES_PATH = os.path.join(ROOT, "rules", "deny-set.json")


class TestRules(unittest.TestCase):
    def setUp(self):
        with open(RULES_PATH) as f:
            self.rules = json.load(f)

    def test_required_keys_present_and_lists(self):
        for k in ("tier1_cmd", "tier1_regex", "tier2_cmd", "tier2_sql_regex",
                  "tier2_regex", "warn_regex", "prod_markers", "allow",
                  "extra_block", "warn_only"):
            self.assertIn(k, self.rules)
            self.assertIsInstance(self.rules[k], list)

    def test_all_regexes_compile(self):
        for k in ("tier1_regex", "tier2_sql_regex", "tier2_regex", "warn_regex"):
            for pat in self.rules[k]:
                re.compile(pat)  # raises if invalid

    def test_cmd_rule_shape(self):
        for k in ("tier1_cmd", "tier2_cmd"):
            for entry in self.rules[k]:
                self.assertIn("seq", entry)
                self.assertIsInstance(entry["seq"], list)
                self.assertTrue(entry["seq"])

    def test_seeds_present(self):
        seqs = json.dumps(self.rules["tier1_cmd"])
        self.assertIn("destroy", seqs)
        self.assertIn("DROP", " ".join(self.rules["tier2_sql_regex"]))


if __name__ == "__main__":
    unittest.main()
