import importlib.util, os, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location(
    "ig", os.path.join(ROOT, "hooks", "irreversible-guard.py"))
ig = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ig)

CWD = "/repo"
RULES = ig.DEFAULT_RULES


def classify(cmd):
    return ig.classify(cmd, RULES, CWD)[0]


class TestBlockAlways(unittest.TestCase):
    def test_rm_dangerous_roots(self):
        for cmd in ("rm -rf /", "rm -rf ~", "rm -rf $HOME",
                    "rm -rf /opt/aruannik/data/*", "rm -rf --no-preserve-root /x",
                    "DEBUG=true rm -rf /", "cd /tmp && rm -rf /"):
            self.assertEqual(classify(cmd), "BLOCK", cmd)

    def test_disk_and_iac_and_cloud(self):
        for cmd in ("dd if=/dev/zero of=/dev/sda", "mkfs.ext4 /dev/sdb", "wipefs -a /dev/sda",
                    "terraform destroy", "ENV=x tofu destroy -auto-approve",
                    "fly volumes destroy vol_123", "railway volume delete",
                    "aws s3 rb s3://b --force", "aws s3 rm s3://b --recursive",
                    "aws rds delete-db-instance --db-instance-identifier x",
                    "gcloud sql instances delete x", "heroku pg:reset",
                    "kubectl delete namespace prod"):
            self.assertEqual(classify(cmd), "BLOCK", cmd)


class TestTransportWrapped(unittest.TestCase):
    def test_ssh_and_docker_to_prod(self):
        for cmd in ("ssh aruannik-live 'rm -rf /opt/aruannik/data/*'",
                    "ssh db-prod \"psql x -c 'DROP TABLE users'\"",
                    "docker exec varustame-prod-api psql d -c 'DROP TABLE annetused'",
                    "docker compose -f docker-compose.production.yml down -v",
                    "ssh db-prod 'psql x <<EOF\nDROP TABLE users;\nEOF'"):
            self.assertEqual(classify(cmd), "BLOCK", cmd)


class TestTier2LocalIsPass(unittest.TestCase):
    def test_local_reversible_pass(self):
        for cmd in ("psql \"$DB\" -c 'DROP TABLE users'", "docker compose down -v",
                    "dotnet ef database drop", "psql local <<EOF\nDROP TABLE t;\nEOF",
                    "docker volume prune"):
            self.assertEqual(classify(cmd), "PASS", cmd)


class TestFalsePositiveGuards(unittest.TestCase):
    def test_routine_pass(self):
        for cmd in ("rm -rf node_modules", "rm -rf .next", "rm -rf build dist",
                    "rm -rf bin obj", "git push origin main", "npm ci",
                    "dotnet ef database update", "echo hi"):
            self.assertEqual(classify(cmd), "PASS", cmd)


class TestWarn(unittest.TestCase):
    def test_recoverable_warn(self):
        for cmd in ("git push --force origin main", "git push -f",
                    "git reset --hard HEAD~3", "git clean -fdx"):
            self.assertEqual(classify(cmd), "WARN", cmd)


class TestConfigBehaviour(unittest.TestCase):
    def test_allow_overrides_block(self):
        rules = dict(ig.DEFAULT_RULES, allow=["rm -rf /"])
        self.assertEqual(ig.classify("rm -rf /", rules, CWD)[0], "PASS")

    def test_warn_only_downgrades_block(self):
        rules = dict(ig.DEFAULT_RULES, warn_only=["terraform destroy"])
        self.assertEqual(ig.classify("terraform destroy", rules, CWD)[0], "WARN")

    def test_extra_block_adds_pattern(self):
        rules = dict(ig.DEFAULT_RULES, extra_block=[r"\bnpm\s+publish\b"])
        self.assertEqual(ig.classify("npm publish", rules, CWD)[0], "BLOCK")


if __name__ == "__main__":
    unittest.main()
