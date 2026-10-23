"""Production native retry policy tests; these do not initialize Chromium."""
import platform
import unittest

import test_lifecycle


@unittest.skipUnless(platform.system() == "Darwin", "Native download fixture requires macOS")
class DownloadRetryTests(unittest.TestCase):
    def test_original_callback_provenance_destination_and_lifecycle(self):
        test_lifecycle.LifecycleContractTests.run_native_fixture(self, "download_retry", link_wrapper=True)


if __name__ == "__main__":
    unittest.main()
