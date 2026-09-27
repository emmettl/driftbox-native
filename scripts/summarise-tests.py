#!/usr/bin/env python3
"""The tests' results in a job's summary on GitHub: how many passed, failed and were skipped, and
what went wrong in each that failed, so a red check says why without opening its log.

    summarise-tests.py --title "Windows tests" .build/tests.xml [.build/midi.xml ...]

Each path is one given to `swift test --xunit-output`, which writes XCTest's results there and
Swift Testing's beside it as `<name>-swift-testing.xml`; both are read. The summary goes to
`$GITHUB_STEP_SUMMARY`, or to stdout off GitHub. It always exits 0: the test step says whether the
tests passed, and this only says how.
"""
import argparse
import os
from pathlib import Path
import sys
import xml.etree.ElementTree as ElementTree

# A failure's message is cut here, so one runaway message cannot swallow the summary; the log has it
# whole.
LONGEST = 600


def result_files(path):
    """The files `swift test --xunit-output path` writes, those that are there."""
    path = Path(path)
    testing = path.with_name(f'{path.stem}-swift-testing{path.suffix}')
    return [candidate for candidate in (path, testing) if candidate.is_file()]


def read(files):
    """Every test case in `files`: (suite, name, outcome, message), outcome one of passed,
    failed or skipped. Counted from the cases rather than the suites' totals, which XCTest and Swift
    Testing count differently."""
    cases = []
    for file in files:
        for case in ElementTree.parse(file).getroot().iter('testcase'):
            problem = case.find('failure')
            if problem is None:
                problem = case.find('error')
            skipped = case.find('skipped')
            if problem is not None:
                message = problem.get('message') or (problem.text or '').strip()
                outcome = 'failed'
            elif skipped is not None:
                message = skipped.get('message') or (skipped.text or '').strip()
                outcome = 'skipped'
            else:
                message, outcome = '', 'passed'
            cases.append((case.get('classname', ''), case.get('name', ''), outcome, message))
    return cases


def cell(text):
    """`text` safe in one cell of a Markdown table."""
    text = ' '.join(text.split())
    if len(text) > LONGEST:
        text = text[:LONGEST - 1] + '…'
    return text.replace('\\', '\\\\').replace('|', '\\|').replace('<', '&lt;').replace('>', '&gt;')


def summary(title, cases):
    """The summary as Markdown."""
    if not cases:
        return (
            f'### {title}: no results\n\n'
            'No test results were written: the tests did not build, or the run stopped before '
            'the end. The log says which.\n')
    failed = [case for case in cases if case[2] == 'failed']
    skipped = [case for case in cases if case[2] == 'skipped']
    passed = len(cases) - len(failed) - len(skipped)
    counts = [f'{passed} passed']
    if failed:
        counts.append(f'{len(failed)} failed')
    if skipped:
        counts.append(f'{len(skipped)} skipped')
    mark = '❌' if failed else '✅'
    lines = [f'### {mark} {title}: {" · ".join(counts)}', '']
    if failed:
        lines += ['| Test | Suite | What went wrong |', '| --- | --- | --- |']
        lines += [f'| `{cell(name)}` | {cell(suite)} | {cell(message)} |' for suite, name, _, message in failed]
        lines.append('')
    if skipped:
        lines += [f'<details><summary>{len(skipped)} skipped</summary>', '']
        lines += [
            f'- `{cell(name)}` in {cell(suite)}' + (f': {cell(message)}' if message else '')
            for suite, name, _, message in skipped]
        lines += ['', '</details>', '']
    return '\n'.join(lines)


def main(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--title', default='Tests')
    parser.add_argument('paths', nargs='+')
    options = parser.parse_args(arguments)
    files = [file for path in options.paths for file in result_files(path)]
    text = summary(options.title, read(files))
    destination = os.environ.get('GITHUB_STEP_SUMMARY')
    if destination:
        with open(destination, 'a', encoding='utf-8') as out:
            out.write(text + '\n')
    else:
        sys.stdout.write(text + '\n')


if __name__ == '__main__':
    main()
