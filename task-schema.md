# UAS Task Schema Reference (Task-UMX)

Standard task definition format for UAS v2 DAG orchestration.

## JSONL Format

One task per line in `.jsonl` files. Each task is a JSON object:

```json
{"id":"build","cmd":"npm run build 2>&1","deps":[],"priority":8,"timeout":120,"retry":2,"desc":"Compile TypeScript"}
{"id":"test","cmd":"npm test 2>&1","deps":["build"],"priority":7,"timeout":180,"retry":1,"desc":"Run unit tests"}
{"id":"lint","cmd":"npx eslint src/ 2>&1","deps":[],"priority":5,"timeout":60,"retry":1,"desc":"Static analysis"}
{"id":"report","cmd":"scripts/gen_report.sh","deps":["test","lint"],"priority":3,"timeout":30,"retry":1,"desc":"Generate summary"}
```

## Field Specification

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique task identifier. Used in dependency references, output filenames, and status tracking. Alphanumeric + underscore/hyphen, max 64 chars. |
| `cmd` | string | Shell command to execute. Runs via `bash -c`. Redirect stderr to stdout with `2>&1` if you want combined output. |

### Optional Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `deps` | string[] | `[]` | Array of task IDs that must complete (status DONE) before this task can start. Empty array = no dependencies. |
| `priority` | int | `5` | Execution priority within a wave. Range 1-10, higher = executes first when competing for worker slots. |
| `timeout` | int | `300` | Maximum execution time in seconds. Task is killed (SIGTERM, then SIGKILL) after this duration. |
| `retry` | int | `1` | Maximum retry attempts on failure. Set to 0 for no retries. Each retry re-executes the full command. |
| `desc` | string | `""` | Human-readable description. Shown in status dashboard and logs. |

## Dependency Rules

1. **Forward-only**: Dependencies must reference tasks defined earlier or in the same file. No circular references.
2. **AND logic**: A task starts only when ALL listed deps have status DONE.
3. **Failure propagation**: If a dependency fails (status FAILED), dependent tasks are marked BLOCKED and not executed.
4. **Missing deps**: If a dep ID doesn't match any task, the scheduler reports an error and marks the task unschedulable.

## Execution Waves

The DAG scheduler groups tasks into waves using topological sort:

```
Wave 0: Tasks with no dependencies (run in parallel)
Wave 1: Tasks whose deps are all in Wave 0 (run after Wave 0 completes)
Wave 2: Tasks whose deps are in Wave 0 or Wave 1
...and so on
```

Within each wave, tasks are ordered by priority (descending). If max-workers
limits parallelism, higher-priority tasks get slots first.

## Task Status Lifecycle

```
PENDING → RUNNING → DONE
                  → FAILED → (retry) → RUNNING
                           → (no retry) → FAILED (terminal)
BLOCKED (dep failed — terminal unless dep is retried and succeeds)
```

Status is tracked in `.uas/status/{task_id}.st` files.

## Examples

### Simple parallel (no dependencies)

```json
{"id":"search_arxiv","cmd":"python3 search.py arxiv 'agent swarm'","priority":5,"timeout":60}
{"id":"search_scholar","cmd":"python3 search.py scholar 'multi-agent'","priority":5,"timeout":60}
{"id":"search_semantic","cmd":"python3 search.py semantic 'LLM orchestration'","priority":5,"timeout":60}
```

All three run in Wave 0 simultaneously.

### Linear chain

```json
{"id":"fetch","cmd":"curl -s https://api.example.com/data > raw.json","deps":[]}
{"id":"parse","cmd":"python3 parse.py raw.json > parsed.csv","deps":["fetch"]}
{"id":"analyze","cmd":"python3 analyze.py parsed.csv > report.md","deps":["parse"]}
```

Wave 0: fetch → Wave 1: parse → Wave 2: analyze

### Diamond dependency

```json
{"id":"fetch","cmd":"download_data.sh","deps":[]}
{"id":"transform_a","cmd":"transform.py --mode a","deps":["fetch"],"priority":8}
{"id":"transform_b","cmd":"transform.py --mode b","deps":["fetch"],"priority":5}
{"id":"merge","cmd":"merge.py a.out b.out","deps":["transform_a","transform_b"]}
```

Wave 0: fetch → Wave 1: transform_a + transform_b (parallel) → Wave 2: merge
