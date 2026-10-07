import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("preflight", Path(__file__).with_name("check.py"))
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class PreflightTests(unittest.TestCase):
    def run_check(self, network=True, outcomes=(True, True, True), adc=True):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            (project / "Makefile").touch()
            output = io.StringIO()
            with patch.object(preflight.shutil, "which", return_value="tool"), \
                 patch.object(preflight, "network_ready", return_value=network), \
                 patch.object(preflight, "command_ready", side_effect=outcomes) as command, \
                 patch.object(preflight, "adc_ready", return_value=adc), \
                 contextlib.redirect_stdout(output):
                status = preflight.check(project, "example-host")
            return status, output.getvalue(), command

    def test_missing_vpn_never_attempts_cloud_or_ssh_auth(self):
        status, message, command = self.run_check(network=False)
        self.assertEqual(status, 11)
        self.assertIn("VPN", message)
        command.assert_not_called()

    def test_cli_and_adc_are_independent_requirements(self):
        for outcomes, expected in [((False,), "CLI"), ((True, False), "ADC")]:
            with self.subTest(expected=expected):
                status, message, _ = self.run_check(outcomes=outcomes)
                self.assertEqual(status, 12 if expected == "CLI" else 13)
                self.assertIn(expected, message)

    def test_python_credential_source_must_also_work(self):
        status, message, command = self.run_check(outcomes=(True, True), adc=False)
        self.assertEqual(status, 14)
        self.assertIn("Python ADC", message)
        self.assertEqual(command.call_count, 2)

    def test_ssh_failure_blocks_execution(self):
        status, message, command = self.run_check(outcomes=(True, True, False))
        self.assertEqual(status, 15)
        self.assertIn("SSH authorization", message)
        self.assertIn("BatchMode=yes", command.call_args.args[0])
        self.assertFalse(any("StrictHostKeyChecking" in argument for argument in command.call_args.args[0]))

    def test_all_conditions_ready(self):
        status, message, _ = self.run_check()
        self.assertEqual(status, 0)
        self.assertIn("READY", message)

    def test_credentials_are_discarded_and_no_interactive_input(self):
        with patch.object(preflight.subprocess, "run") as run:
            run.return_value.returncode = 0
            self.assertTrue(preflight.command_ready(["gcloud", "auth", "print-access-token"]))
            options = run.call_args.kwargs
            self.assertEqual(options["stdout"], preflight.subprocess.DEVNULL)
            self.assertEqual(options["stderr"], preflight.subprocess.DEVNULL)
            self.assertEqual(options["stdin"], preflight.subprocess.DEVNULL)
            self.assertEqual(options["timeout"], 10)


if __name__ == "__main__":
    unittest.main()
