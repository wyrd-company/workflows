import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "bin/t3code-stable-release-watch-run.py"
spec = importlib.util.spec_from_file_location("watch", SCRIPT)
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)


def feed(*tags):
    entries = "".join(f"<entry><id>tag:github.com,2008:Repository/7/{tag}</id></entry>" for tag in tags)
    return f'<feed xmlns="http://www.w3.org/2005/Atom">{entries}</feed>'.encode()


class StableReleaseWatchTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        self.state = root / "state"
        self.project = str(root / "client")
        self.manifest = Path(self.project) / "main/packages/t3code-lib/package.json"
        self.manifest.parent.mkdir(parents=True)
        self.manifest.write_text(json.dumps({"devDependencies": {"t3": "0.1.10"}}))
        self.fetch = self.enterContext(patch.object(watch, "fetch"))
        self.t3 = self.enterContext(patch.object(watch, "t3_json"))

    def run_check(self):
        watch.check(self.state, self.project, "example", "setup-thread")

    def test_latest_stable_tag_in_feed_launches_once(self):
        self.fetch.return_value = feed("v0.1.12", "v0.1.100-nightly.1", "mobile/v0.1.100", "v0.2.0")
        self.t3.side_effect = [[], {"threadId": "release-thread", "runId": "release-run"}]
        self.run_check()
        args, kwargs = self.t3.call_args
        self.assertEqual(args, (
            "start", "--title", "Update and release t3code-client for T3 Code v0.2.0", self.project, "-",
        ))
        self.assertIn("git operator set --from setup-thread", kwargs["prompt"])
        self.assertIn("/releases/tag/v0.2.0", kwargs["prompt"])
        self.assertEqual(json.loads((self.state / "last-launch.json").read_text()), {
            "tag": "v0.2.0", "threadId": "release-thread",
        })

        self.fetch.side_effect = [self.fetch.return_value, json.dumps({"tag_name": "v0.2.0"})]
        self.run_check()
        self.assertEqual(self.t3.call_count, 2)

    def test_feed_without_new_stable_tag_uses_latest_release_endpoint(self):
        self.fetch.side_effect = [feed("v0.1.11", "v0.1.12-nightly.1"), json.dumps({"tag_name": "v0.1.12"})]
        self.t3.side_effect = [[], {"threadId": "release-thread", "runId": "release-run"}]
        self.run_check()
        self.assertEqual(self.fetch.call_args.args, (watch.LATEST,))
        self.assertIn("v0.1.12", self.t3.call_args.args[2])

    def test_existing_client_target_and_initial_baseline_do_not_launch(self):
        for target, tag in [("0.1.10", "v0.1.11"), ("0.1.13", "v0.1.13")]:
            with self.subTest(target=target, tag=tag):
                self.manifest.write_text(json.dumps({"devDependencies": {"t3": target}}))
                self.fetch.side_effect = [feed(tag), json.dumps({"tag_name": tag})]
                self.run_check()
                self.t3.assert_not_called()
                self.assertFalse((self.state / "last-launch.json").exists())

    def test_lost_launch_reply_recovers_the_existing_thread(self):
        self.fetch.return_value = feed("v0.1.12")
        self.t3.side_effect = [[], subprocess.CalledProcessError(1, "t3")]
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_check()
        self.assertFalse((self.state / "last-launch.json").exists())

        self.t3.side_effect = [[{
            "title": "Update and release t3code-client for T3 Code v0.1.12",
            "threadId": "release-thread",
        }]]
        self.run_check()
        self.assertEqual(self.t3.call_count, 3)
        self.assertEqual(json.loads((self.state / "last-launch.json").read_text())["threadId"], "release-thread")


if __name__ == "__main__":
    unittest.main()
