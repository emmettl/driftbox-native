#!/usr/bin/env python3
"""Check the tests' summary reads both of `swift test`'s result files and says what failed."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    'summarise_tests', Path(__file__).with_name('summarise-tests.py'))
summarise = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summarise)

# As Swift Testing writes them: one suite for the run, a case for each test.
TESTING = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
    <testsuite name="TestResults" errors="0" tests="0" failures="0" skipped="0" time="0.0001"/>
    <testsuite name="TestResults" errors="0" tests="3" failures="1" skipped="1" time="13.0">
        <testcase classname="DriftboxDesktopTests.DesktopTests" name="aScreenReaderIsTold()" time="1.0"/>
        <testcase classname="DriftboxDesktopTests.DesktopTests" name="aPassingOne()" time="1.0"/>
        <testcase classname="DriftboxDesktopTests.DesktopTests" name="theSongIsExportedAsAudio()" time="96.4">
            <failure message="Caught error: The file doesn’t exist. | NSFilePath=C:/Temp/Groove.wav"/>
        </testcase>
        <testcase classname="DriftboxDesktopTests.DesktopTests" name="notToday()">
            <skipped>needs a display</skipped>
        </testcase>
    </testsuite>
</testsuites>
"""

# As XCTest writes them: a suite for each class.
XCTEST = """<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
    <testsuite name="DriftboxEngineTests.ClockTests" errors="1" tests="2" failures="0" time="0.1">
        <testcase classname="DriftboxEngineTests.ClockTests" name="testTicks" time="0.05"/>
        <testcase classname="DriftboxEngineTests.ClockTests" name="testDrift" time="0.05">
            <error message="Late by 4ms &lt;expected 1ms&gt;"/>
        </testcase>
    </testsuite>
</testsuites>
"""


class SummaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)

    def results(self, name, xctest=None, testing=None):
        path = self.directory / f'{name}.xml'
        if xctest is not None:
            path.write_text(xctest, encoding='utf-8')
        if testing is not None:
            (self.directory / f'{name}-swift-testing.xml').write_text(testing, encoding='utf-8')
        return path

    def summarised(self, *paths, title='Windows tests'):
        out = self.directory / 'summary.md'
        with mock.patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': str(out)}):
            summarise.main(['--title', title, *map(str, paths)])
        return out.read_text(encoding='utf-8')

    def test_both_files_are_read_and_the_failures_listed(self):
        text = self.summarised(self.results('tests', XCTEST, TESTING))
        self.assertIn('### ❌ Windows tests: 3 passed · 2 failed · 1 skipped', text)
        self.assertIn('| `theSongIsExportedAsAudio()` | DriftboxDesktopTests.DesktopTests |', text)
        self.assertIn('The file doesn’t exist. \\| NSFilePath', text, 'a pipe does not end the cell')
        self.assertIn('Late by 4ms &lt;expected 1ms&gt;', text, 'an error is a failure too')
        self.assertIn('- `notToday()` in DriftboxDesktopTests.DesktopTests: needs a display', text)

    def test_several_runs_make_one_summary(self):
        first = self.results('tests', testing=TESTING)
        second = self.results('midi', xctest=XCTEST)
        self.assertIn('3 passed · 2 failed · 1 skipped', self.summarised(first, second))

    def test_all_passing_is_one_line(self):
        passing = TESTING.replace(
            '<failure message="Caught error: The file doesn’t exist. | NSFilePath=C:/Temp/Groove.wav"/>', '')
        text = self.summarised(self.results('tests', testing=passing), title='Linux tests')
        self.assertTrue(text.startswith('### ✅ Linux tests: 3 passed · 1 skipped'))
        self.assertNotIn('| Test |', text)

    def test_no_results_says_so(self):
        text = self.summarised(self.directory / 'never.xml')
        self.assertIn('### Windows tests: no results', text)

    def test_a_long_message_is_cut(self):
        long = TESTING.replace('Caught error:', 'Caught error: ' + 'x' * 2000)
        text = self.summarised(self.results('tests', testing=long))
        row = next(line for line in text.splitlines() if 'theSongIsExportedAsAudio' in line)
        self.assertLess(len(row), summarise.LONGEST + 200)
        self.assertIn('…', row)


if __name__ == '__main__':
    unittest.main()
