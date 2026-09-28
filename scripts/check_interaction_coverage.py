#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Combine executed evidence. Test declarations and repeated passes are not coverage."""
import json
import math
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
inventory = json.loads((root / "inventory.json").read_text())
faults = json.loads((root / "faults.json").read_text())["results"]
benchmark = json.loads((root / "benchmark.json").read_text())
tests = (root / "deterministic.log").read_text()
ui = json.loads((root / "ui-tests.json").read_text())
ui_names = set()

def collect(nodes):
    for node in nodes:
        if node.get("nodeType") == "Test Case" and node.get("result") == "Passed":
            ui_names.add(node["name"].removesuffix("()"))
        collect(node.get("children", []))

collect(ui.get("testNodes", []))
required_ui = {
    "taskReview": "testOfferedReviewAnswerUsesVisibleQuestion",
    "chooseDate": "testDateAnswerSurvivesSocialReplyAndRelaunch",
    "chooseTask": "testTaskChoiceUsesNamedCandidate",
    "taskEdit": "testUpcomingGroupsHistoryAndManualDateClearing",
}
passed_cases = {row["id"] for row in benchmark["rows"] if not row["failures"]}
failures = []
required_matrices = {
    "command-vs-title": {f"command-title-{title}-{verb}-{review}" for title in range(7)
                         for verb in range(3) for review in ("false", "true")},
    "date-and-rollover": {f"matrix-{kind}-{boundary}" for kind in ("clock", "rollover")
                          for boundary in ("year", "leap", "dst-us", "dst-uk")},
    "meaning-and-list-state": {f"matrix-negation-{title}-{state}" for title in range(3) for state in range(3)},
    "context-transitions": {"family-query-break", "family-restart-question", "family-focus-competition",
                            "family-topic-switch", "family-cancel-question", "family-no-context-restart"},
}
matrix_coverage = {}
for name, required in required_matrices.items():
    missing = sorted(required - passed_cases)
    matrix_coverage[name] = {"requiredScenarios": len(required), "missingScenarios": missing}
    if missing:
        failures.append("missing matrix coverage: " + name)
contracts = []
for item in inventory:
    missing_tests = [name for name in item["requiredTests"] if f"Test {name}() passed" not in tests]
    missing_cases = sorted(set(item["requiredScenarios"]) - passed_cases)
    ui_passed = required_ui.get(item["contract"]) in ui_names
    passed = bool(item["requiredTests"]) and not missing_tests and not missing_cases
    if item["requiredUILayer"] and not ui_passed:
        passed = False
    if not passed:
        failures.append("uncovered contract: " + item["contract"])
    contracts.append(dict(item, passed=passed, missingTests=missing_tests, missingScenarios=missing_cases,
                          renderedUITested=ui_passed, realInterpreterTested=bool(item["requiredScenarios"])))

required_faults = {"control", "lost-context", "wrong-target", "wrong-status", "duplicate-action", "missing-save", "false-success", "unrelated-field"}
if {item["fault"] for item in faults if item["passed"]} != required_faults:
    failures.append("fault detection did not distinguish all required mutants and the good control")
if not benchmark["completed"] or not benchmark["passed"]:
    failures.append("benchmark incomplete or failed")

def timing(rows):
    values = sorted(row["seconds"] for row in rows)
    return {"samples": len(values), "p95Seconds": values[math.ceil(.95 * len(values)) - 1] if values else None,
            "maxSeconds": max(values) if values else None}

rows = benchmark["rows"]
routes = {
    "generation": timing([row for row in rows if "modelCall" in row["events"]]),
    "deterministicOrClarification": timing([row for row in rows if "modelCall" not in row["events"]]),
    "recovery": timing([row for row in rows if "recovery" in row["events"]]),
}
for route, stats in routes.items():
    if stats["p95Seconds"] is not None and stats["p95Seconds"] > 15:
        failures.append("route latency exceeds 15 seconds: " + route)
first_generation = next((row["seconds"] for row in rows if "modelCall" in row["events"]), None)
category_rows = {}
for category in sorted({row["category"] for row in rows}):
    group = [row for row in rows if row["category"] == category]
    category_rows[category] = {"distinctScenarios": len({row["id"] for row in group}), "turnExecutions": len(group),
                               "failedTurns": sum(bool(row["failures"]) for row in group), **timing(group)}
report = {"passed": not failures, "failures": failures, "contracts": contracts, "faultInjection": faults,
          "matrices": matrix_coverage,
          "categories": category_rows, "routeLatencies": routes, "firstGenerationInProcessSeconds": first_generation,
          "modelCacheState": "unknown; first generation is not proof of an uncached system model",
          "distinctScenarios": len({row["id"] for row in rows}), "turnExecutions": len(rows),
          "renderedUI": "Simulator with parser fixture; separate live device benchmark uses the real model",
          "notCovered": ["Exhaustive language coverage", "All physical-device accessibility and keyboard layouts",
                         "System-model cache eviction / truly cold OS model load", "Live iCloud and Calendar service failures (adapters are isolated)"]}
(root / "coverage.json").write_text(json.dumps(report, indent=2) + "\n")
print(f"Interaction gate: {'PASS' if report['passed'] else 'FAIL'}; {len(contracts)} contracts; "
      f"{report['distinctScenarios']} distinct scenarios, {len(rows)} turn executions.")
for failure in failures:
    print(failure)
sys.exit(0 if report["passed"] else 1)
