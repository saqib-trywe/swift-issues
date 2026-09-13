#!/usr/bin/env python3
"""Enforce ticket 13's coverage rules.

Two gates:

  1. Per-target floors. A target below its floor fails.
  2. No regression. A target below its recorded baseline fails, even if it is
     still above the floor — this is the rule that actually catches a rushed
     feature landing untested.

The baseline lives in a committed file rather than an external service: no new
dependency, the number stays visible in git history, and CI does not have to run
the base branch as well to find out what changed. The cost is that a legitimate
coverage *increase* needs a deliberate bump, which also makes it visible in
review.

Usage:
    swift test --enable-code-coverage
    python3 Scripts/check-coverage.py [--update-baseline]
"""

import json
import pathlib
import subprocess
import sys

# Ticket 13. View bodies are deliberately ungated; a uniform target would push
# people to assert that a VStack contains a Text to move a number.
FLOORS = {
    "Core": 90.0,
    "Server": 80.0,
    "CLI": 70.0,
    "MCP": 70.0,
    # Below Core's 90 because the engine has GRDB and transport paths that are
    # awkward to reach; above the server's 80 because silent divergence is the
    # worst failure this project has.
    "ClientStore": 85.0,
    # Ticket 13: view models 80%, view bodies ungated. This target holds the
    # models; the app shells that hold the view bodies are outside the package.
    "AppCore": 80.0,
}

# Absorbs cross-toolchain variance, not slack. Xcode's Swift 6.3.3
# (swiftlang-6.3.3.1.3) and swiftly's Swift 6.3.3 (swift-6.3.3-RELEASE) are the
# same version but different builds, and they attribute coverage regions slightly
# differently — CI reported Core 0.05% below a figure that was stable across three
# local runs, which is under one line. A gate that fails on less than a line is one
# people learn to override, and that costs more than it catches: a real regression
# moves the number far further than this.
TOLERANCE = 0.3
BASELINE_PATH = pathlib.Path(".coverage-baseline.json")


def profile_path() -> pathlib.Path:
    result = subprocess.run(
        ["swift", "test", "--enable-code-coverage", "--show-codecov-path"],
        capture_output=True, text=True, check=True,
    )
    return pathlib.Path(result.stdout.strip())


def measure() -> dict[str, tuple[int, int]]:
    """Returns target -> (covered, total) for source targets only."""
    path = profile_path()
    if not path.exists():
        print(
            "No coverage profile at "
            f"{path}.\nRun `swift test --enable-code-coverage` first — note that a "
            "failing test run produces no profile."
        )
        raise SystemExit(1)
    data = json.loads(path.read_text())
    totals: dict[str, tuple[int, int]] = {}
    for entry in data["data"][0]["files"]:
        name = entry["filename"]
        if "/Sources/" not in name:
            continue
        target = name.split("/Sources/", 1)[1].split("/", 1)[0]
        if target not in FLOORS:
            continue  # TestSupport and friends are not gated
        lines = entry["summary"]["lines"]
        covered, total = totals.get(target, (0, 0))
        totals[target] = (covered + lines["covered"], total + lines["count"])
    return totals


def main() -> int:
    updating = "--update-baseline" in sys.argv
    measured = measure()
    baseline = json.loads(BASELINE_PATH.read_text()) if BASELINE_PATH.exists() else {}

    if updating:
        new = {t: round(100 * c / n, 2) for t, (c, n) in sorted(measured.items()) if n}
        BASELINE_PATH.write_text(json.dumps(new, indent=2) + "\n")
        print(f"Baseline updated: {new}")
        return 0

    failures: list[str] = []
    print(f"{'Target':<12}{'Coverage':>10}{'Floor':>8}{'Baseline':>10}")
    for target, (covered, total) in sorted(measured.items()):
        if not total:
            continue
        percent = 100 * covered / total
        floor = FLOORS[target]
        recorded = baseline.get(target)
        shown = f"{recorded:.2f}%" if recorded is not None else "—"
        print(f"{target:<12}{percent:>9.2f}%{floor:>7.0f}%{shown:>10}")

        if percent + TOLERANCE < floor:
            failures.append(
                f"{target} is {percent:.2f}%, below its floor of {floor:.0f}%."
            )
        if recorded is not None and percent + TOLERANCE < recorded:
            failures.append(
                f"{target} fell from {recorded:.2f}% to {percent:.2f}%. "
                "Add tests, or bump the baseline deliberately with "
                "`python3 Scripts/check-coverage.py --update-baseline`."
            )

    for target in FLOORS:
        if target in baseline and target not in measured:
            failures.append(f"{target} has a baseline but produced no coverage data.")

    if failures:
        print("\nCoverage check failed:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("\nCoverage check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
