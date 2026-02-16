# UAS Workflow Templates

Ready-to-use patterns for common orchestration scenarios.

---

## Template 1: Code Review Swarm

Parallel lint + test + security scan with merged report.

### tasks.jsonl

```json
{"id":"lint","cmd":"find src/ -name '*.py' -exec python3 -m py_compile {} + 2>&1 | tee /tmp/lint.log && echo PASS || echo FAIL"}
{"id":"test","cmd":"python3 -m pytest tests/ --tb=short 2>&1 | tee /tmp/test.log"}
{"id":"security","cmd":"grep -rn 'eval\\|exec\\|subprocess.call\\|os.system' src/ 2>&1 | tee /tmp/security.log || echo 'no findings'"}
```

### hooks.json

```json
{
  "hooks": {
    "post-exec": ["scripts/check_output_nonempty.sh"],
    "on-complete": ["scripts/merge_reports.sh"]
  }
}
```

### Usage

```bash
bash scripts/orchestrate.sh tasks/code_review.jsonl --hooks hooks.json --max-workers 3
```

---

## Template 2: Research Pipeline

Sequential: search → extract → analyze → synthesize.

### stages/

```
stages/
├── 01_search.sh       # Fetch raw data
├── 02_extract.sh      # Parse key information
├── 03_analyze.sh      # Run analysis
└── 04_synthesize.sh   # Generate summary
```

### Usage

```bash
bash scripts/pipeline.sh stages/ --hooks hooks.json --input query.txt
```

---

## Template 3: Data Processing (Fan-Out / Fan-In)

Split large file → parallel transform → merge.

### Preparation

```bash
mkdir -p /tmp/uas-chunks
split -l 1000 data/large.csv /tmp/uas-chunks/chunk_
```

### Generate tasks

```bash
for chunk in /tmp/uas-chunks/chunk_*; do
  id=$(basename "$chunk")
  echo "{\"id\":\"$id\",\"cmd\":\"python3 transform.py $chunk\"}"
done > tasks/process.jsonl
```

### Run

```bash
bash scripts/orchestrate.sh tasks/process.jsonl --max-workers 6
```

---

## Template 4: Build & Validate

Compile → test → quality gate → deploy.

### Pipeline stages

```
stages/
├── 01_build.sh
├── 02_test.sh
└── 03_deploy.sh
```

### Gate hook

```bash
#!/bin/bash
# hooks/quality_gate.sh
if grep -q "FAIL\|Error" "$1"; then
  echo "Quality gate: BLOCKED"
  exit 1
fi
echo "Quality gate: PASS"
```

---

## Template 5: Document Generation

Outline → parallel section writing → merge.

### tasks.jsonl

```json
{"id":"intro","cmd":"python3 write_section.py intro"}
{"id":"methods","cmd":"python3 write_section.py methods"}
{"id":"results","cmd":"python3 write_section.py results"}
{"id":"conclusion","cmd":"python3 write_section.py conclusion"}
```

### Merge on-complete

```bash
#!/bin/bash
# hooks/merge_doc.sh
for s in intro methods results conclusion; do
  cat "results/${s}.out"
  echo ""
done > final_document.md
```

---

## Template 6: Multi-Source Aggregation

Parallel fetch from N sources → normalize → merge.

### tasks.jsonl

```json
{"id":"source_a","cmd":"curl -s 'https://api.example.com/data' | python3 normalize.py"}
{"id":"source_b","cmd":"python3 scrape_source_b.py | python3 normalize.py"}
{"id":"source_c","cmd":"cat local_data.csv | python3 normalize.py"}
```

### Usage

```bash
bash scripts/orchestrate.sh tasks/aggregate.jsonl --max-workers 3
# Then merge: cat results/*.out | python3 merge.py > aggregated.json
```
