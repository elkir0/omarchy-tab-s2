import os
import tempfile
import unittest

import testutil  # noqa: F401
from shannond import region as R


class RegionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "omatel", "settings.toml")

    def read(self):
        with open(self.path) as f:
            return f.read()

    def write(self, text):
        os.makedirs(os.path.dirname(self.path))
        with open(self.path, "w") as f:
            f.write(text)

    def test_region_of(self):
        for number, region in (("+12025550100", "US"), ("+33 6 39 98 00 00", "FR"), ("+590000000000", "GP"),
                               ("+596000000000", "MQ"), ("+262000000000", "RE")):
            self.assertEqual(R.region_of(number), region)
        for number in ("0639980000", "", None, "+999123"):
            self.assertIsNone(R.region_of(number))

    def test_no_file_yet(self):
        self.assertTrue(R.fill("+12025550100", self.path))
        self.assertEqual(self.read(), 'region = "US"\n')

    def test_an_empty_setting_is_filled_and_the_rest_kept(self):
        self.write('delivery_reports = true\nregion = ""\nquick_replies = ["a"]\n')
        self.assertTrue(R.fill("+12025550100", self.path))
        self.assertEqual(self.read().splitlines(), ['region = "US"', "delivery_reports = true", 'quick_replies = ["a"]'])

    def test_the_owner_s_choice_stays(self):
        self.write('region = "CA"\n')
        self.assertTrue(R.fill("+12025550100", self.path))
        self.assertEqual(self.read(), 'region = "CA"\n')

    def test_an_unknown_line_keeps_the_locale(self):
        self.assertFalse(R.fill("+999123", self.path))
        self.assertFalse(os.path.exists(self.path))


if __name__ == "__main__":
    unittest.main()
