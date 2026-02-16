#!/usr/bin/env python3
"""dag_scheduler.py — Topological sort + wave generation for UAS task DAGs.

Usage: python3 dag_scheduler.py <tasks.jsonl>
Output: JSON array of execution waves to stdout.

Each wave contains tasks whose dependencies are all satisfied by
previous waves. Tasks within a wave can run in parallel.
Tasks are sorted by priority (descending) within each wave.
"""

import json
import sys
from collections import defaultdict, deque


def load_tasks(path):
    tasks = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            task = json.loads(line)
            tid = task["id"]
            task.setdefault("deps", [])
            task.setdefault("priority", 5)
            task.setdefault("timeout", 300)
            task.setdefault("retry", 1)
            task.setdefault("desc", "")
            tasks[tid] = task
    return tasks


def detect_cycles(tasks):
    """Detect circular dependencies. Returns list of cycle members or empty."""
    visited = set()
    in_stack = set()
    cycle_nodes = []

    def dfs(node):
        visited.add(node)
        in_stack.add(node)
        for dep in tasks.get(node, {}).get("deps", []):
            if dep not in tasks:
                continue
            if dep not in visited:
                if dfs(dep):
                    return True
            elif dep in in_stack:
                cycle_nodes.append(node)
                return True
        in_stack.discard(node)
        return False

    for tid in tasks:
        if tid not in visited:
            if dfs(tid):
                return cycle_nodes
    return []


def compute_waves(tasks):
    """Kahn's algorithm — group tasks into dependency-resolved waves."""
    in_degree = defaultdict(int)
    dependents = defaultdict(list)

    for tid, task in tasks.items():
        if tid not in in_degree:
            in_degree[tid] = 0
        for dep in task["deps"]:
            if dep in tasks:
                in_degree[tid] += 1
                dependents[dep].append(tid)

    # Wave 0: all tasks with no dependencies
    queue = deque([tid for tid, deg in in_degree.items() if deg == 0])
    waves = []

    while queue:
        # Current wave: all ready tasks, sorted by priority desc
        wave = sorted(queue, key=lambda t: -tasks[t].get("priority", 5))
        waves.append(wave)
        next_queue = deque()
        for tid in wave:
            for dep_tid in dependents[tid]:
                in_degree[dep_tid] -= 1
                if in_degree[dep_tid] == 0:
                    next_queue.append(dep_tid)
        queue = next_queue

    # Check for unscheduled tasks (part of cycles or broken deps)
    scheduled = set()
    for w in waves:
        scheduled.update(w)
    unscheduled = [tid for tid in tasks if tid not in scheduled]

    return waves, unscheduled


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 dag_scheduler.py <tasks.jsonl>", file=sys.stderr)
        sys.exit(1)

    tasks = load_tasks(sys.argv[1])

    if not tasks:
        print(json.dumps({"waves": [], "errors": ["No tasks found"]}))
        sys.exit(0)

    cycles = detect_cycles(tasks)
    if cycles:
        print(json.dumps({
            "waves": [],
            "errors": [f"Circular dependency detected involving: {', '.join(cycles)}"]
        }))
        sys.exit(1)

    waves, unscheduled = compute_waves(tasks)

    result = {
        "waves": [
            {
                "wave": i,
                "tasks": [
                    {
                        "id": tid,
                        "cmd": tasks[tid]["cmd"],
                        "priority": tasks[tid]["priority"],
                        "timeout": tasks[tid]["timeout"],
                        "retry": tasks[tid]["retry"],
                        "desc": tasks[tid]["desc"]
                    }
                    for tid in wave
                ]
            }
            for i, wave in enumerate(waves)
        ],
        "total_tasks": len(tasks),
        "total_waves": len(waves),
        "errors": [f"Unschedulable (broken deps): {tid}" for tid in unscheduled]
    }

    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
