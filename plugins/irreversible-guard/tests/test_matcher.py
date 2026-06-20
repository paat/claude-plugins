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


class TestEvasionRegression(unittest.TestCase):
    """Bypasses found in adversarial review; each must now be caught."""

    def test_double_slash_root_no_crash(self):  # F1: was IndexError -> fail-open
        self.assertEqual(classify("rm -rf //"), "BLOCK")
        self.assertEqual(classify("rm -rf /./"), "BLOCK")

    def test_lowercase_sql_against_prod(self):  # F2: SQL is case-insensitive
        self.assertEqual(classify("ssh db-prod 'psql -c \"drop table users\"'"), "BLOCK")
        self.assertEqual(classify("ssh db-prod 'psql -c \"truncate annetused\"'"), "BLOCK")

    def test_hyphenated_docker_compose_prod(self):  # F3
        self.assertEqual(
            classify("docker-compose -f docker-compose.production.yml down -v"), "BLOCK")

    def test_global_flags_before_subcommand(self):  # F4
        for cmd in ("terraform -chdir=env/prod destroy -auto-approve",
                    "aws --profile prod s3 rb s3://bucket --force",
                    "kubectl --context prod delete namespace app",
                    "gcloud --project=p sql instances delete x"):
            self.assertEqual(classify(cmd), "BLOCK", cmd)

    def test_ssh_double_dash_separator(self):  # F5
        self.assertEqual(classify("ssh host -- rm -rf /"), "BLOCK")

    def test_no_new_false_positives(self):
        for cmd in ("aws s3 ls", "aws s3 cp a s3://b/rb", "terraform plan",
                    "terraform plan -out destroy.tfplan", "kubectl get namespace",
                    "git push origin main", "dotnet ef database update",
                    "docker compose up -d"):
            self.assertEqual(classify(cmd), "PASS", cmd)


class TestCodexRegression(unittest.TestCase):
    """Second-round bypasses found by codex review; each must now be caught."""

    def test_docker_exec_inner_recursed(self):  # F1
        for cmd in ("docker exec api-prod bash -c 'rm -rf /'",
                    "docker exec api-prod sh -c 'terraform destroy'",
                    "docker exec api-prod eval 'rm -rf /'"):
            self.assertEqual(classify(cmd), "BLOCK", cmd)

    def test_combined_shell_flags(self):  # F2
        for cmd in ("bash -lc 'rm -rf /'", "sh -ec 'terraform destroy'",
                    "ssh prod-host 'bash -lc \"rm -rf /\"'"):
            self.assertEqual(classify(cmd), "BLOCK", cmd)

    def test_env_prefix_prod_marker_retained(self):  # F3
        for cmd in ("PROD_DATABASE_URL=postgres://prod-db psql -c 'DROP TABLE users'",
                    "DATABASE_URL=postgres://prod-db psql -c 'TRUNCATE users'"):
            self.assertEqual(classify(cmd), "BLOCK", cmd)

    def test_terraform_apply_destroy(self):  # F4
        for cmd in ("terraform apply -destroy -auto-approve",
                    "tofu apply -destroy -auto-approve"):
            self.assertEqual(classify(cmd), "BLOCK", cmd)

    def test_kubectl_plural_resources(self):  # F5
        for cmd in ("kubectl delete namespaces --all",
                    "kubectl delete persistentvolumes --all",
                    "kubectl delete persistentvolumeclaims --all -n prod"):
            self.assertEqual(classify(cmd), "BLOCK", cmd)

    def test_critical_top_level_globs(self):  # F6
        for cmd in ("rm -rf /etc/*", "rm -rf /home/*", "rm -rf /usr/*"):
            self.assertEqual(classify(cmd), "BLOCK", cmd)

    def test_sql_in_files_not_blocked(self):  # F7 (false positive)
        for cmd in ("echo 'DROP TABLE users;' > production-migration.sql",
                    "grep -R 'DROP TABLE' docs/production-migrations.md",
                    "cat > production-cleanup.sql <<'EOF'\nDROP TABLE old_users;\nEOF"):
            self.assertEqual(classify(cmd), "PASS", cmd)

    def test_docker_global_flags_before_subcommand(self):  # F8
        for cmd in ("docker --context prod volume prune -f",
                    "docker --context prod volume rm db-data",
                    "docker --context prod compose down -v"):
            self.assertEqual(classify(cmd), "BLOCK", cmd)


class TestCodexRound3(unittest.TestCase):
    """Third-round bypasses/false-positives; each must behave as asserted."""

    def test_env_wrapper_unwrapped(self):  # F1
        self.assertEqual(classify("env rm -rf /"), "BLOCK")
        self.assertEqual(
            classify("env PROD_DATABASE_URL=postgres://prod-db psql -c 'DROP TABLE users'"),
            "BLOCK")

    def test_quote_aware_split_preserves_recursion(self):  # F2
        self.assertEqual(classify("bash -c 'echo ok && terraform destroy'"), "BLOCK")
        self.assertEqual(
            classify("ssh db-prod 'echo ok && psql -c \"DROP TABLE users\"'"), "BLOCK")

    def test_shell_value_options_before_c(self):  # F3
        self.assertEqual(classify("bash -O extglob -c 'rm -rf /'"), "BLOCK")
        self.assertEqual(classify("bash -o pipefail -c 'terraform destroy'"), "BLOCK")

    def test_compose_exec_prod_marker_kept(self):  # F4
        self.assertEqual(
            classify("docker compose -f docker-compose.production.yml exec db "
                     "psql -c 'DROP TABLE users'"), "BLOCK")

    def test_redirect_target_not_db_client(self):  # F5 (false positive)
        self.assertEqual(
            classify("cat > prod/psql <<'EOF'\nDROP TABLE users;\nEOF"), "PASS")

    def test_var_tmp_not_protected(self):  # F6 (false positive)
        self.assertEqual(classify("rm -rf /var/tmp/myapp-cache"), "PASS")
        self.assertEqual(classify("rm -rf /var/lib/postgresql"), "BLOCK")

    def test_prod_substring_not_marked(self):  # latent false positive
        self.assertEqual(classify("psql -c 'DROP TABLE products'"), "PASS")
        self.assertEqual(classify("psql -c 'DROP TABLE delivery'"), "PASS")


class TestCodexRound4(unittest.TestCase):
    """Fourth-round bypasses/false-positives; each must behave as asserted."""

    def test_background_and_pipe_amp_split(self):  # F1, F2
        self.assertEqual(classify("echo x |& rm -rf /opt/app/data/*"), "BLOCK")
        self.assertEqual(classify("sleep 1 & rm -rf /opt/app/data/*"), "BLOCK")

    def test_env_split_string(self):  # F3
        self.assertEqual(classify("env -S 'rm -rf /opt/app/data/*'"), "BLOCK")
        self.assertEqual(classify("env -S'terraform destroy'"), "BLOCK")

    def test_prod_with_adjacent_digits(self):  # F4
        for cmd in ("ssh prod1 'psql -c \"DROP TABLE users\"'",
                    "ssh prod01 'psql -c \"DROP TABLE users\"'"):
            self.assertEqual(classify(cmd), "BLOCK", cmd)

    def test_deep_nesting_not_dropped(self):  # F5
        self.assertEqual(
            classify("eval eval eval eval eval eval rm -rf /opt/app/data/*"), "BLOCK")

    def test_echo_of_sql_not_blocked(self):  # F6 (false positive)
        self.assertEqual(
            classify("docker exec api-prod bash -c \"echo psql 'DROP TABLE users'\""), "PASS")

    def test_command_wrapper_unwrapped(self):  # F7
        self.assertEqual(
            classify("command psql postgres://prod-db/app -c 'DROP TABLE users'"), "BLOCK")
        self.assertEqual(classify("nohup terraform destroy -auto-approve"), "BLOCK")

    def test_redirects_not_missplit(self):  # guard against new false positives from & split
        self.assertEqual(classify("psql -c 'select 1' 2>&1"), "PASS")
        self.assertEqual(classify("echo hi &> /tmp/log"), "PASS")


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
