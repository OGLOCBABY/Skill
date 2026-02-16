# UAS Workflow Templates

Ready-to-use patterns for common orchestration scenarios.

---

## Template 1: Code Review Swarm

Parallel lint + test + security scan → merged report.

### tasks.jsonl

```json
{"id":"lint","cmd":"find src/ -name '*.py' -exec python3 -m py_compile {} + 2>&1 | tee /tmp/lint.log && echo PASS || echo FAIL","deps":[],"priority":5,"timeout":60}
{"id":"test","cmd":"python3 -m pytest tests/ --tb=short 2>&1 | tee /tmp/test.log","deps":[],"priority":7,"timeout":120}
{"id":"security","cmd":"grep -rn 'eval\\|exec\\|subprocess.call\\|os.system' src/ 2>&1 | tee /tmp/security.log || echo 'no findings'","deps":[],"priority":5,"timeout":30}
{"id":"report","cmd":"echo '# Code Review Report' && echo '## Lint' && cat /tmp/lint.log && echo '## Tests' && cat /tmp/test.log && echo '## Security' && cat /tmp/security.log","deps":["lint","test","security"],"priority":3,"timeout":30}
```

### Usage

```bash
bash scripts/orchestrate.sh tasks/code_review.jsonl --hooks hooks.json --max-workers 4
```

Wave 0: lint + test + security (parallel) → Wave 1: report

---

## Template 2: Research Pipeline

Search → Extract → Analyze → Synthesize (sequential with gates).

### stages/

```
stages/
├── 01_search.sh       # Fetch raw data / search results
├── 02_extract.sh      # Parse and extract key information
├── 03_analyze.sh      # Run analysis on extracted data
└── 04_synthesize.sh   # Generate final synthesis / summary
```

### Gate hook

```bash
#!/bin/bash
# hooks/gate_check.sh — verify stage output is non-empty and valid
FILE=$1
[ -s "$FILE" ] || { echo "Empty output"; exit 1; }
python3 -c "
import sys
content = open('$FILE').read()
if len(content) < 50:
    print('Output too short, likely failed')
    sys.exit(1)
print('Gate: PASS')
"
```

### Usage

```bash
bash scripts/pipeline.sh stages/ --hooks hooks.json --input data/query.txt
```

---

## Template 3: Data Processing (Fan-Out / Fan-In)

Split large file → parallel transform → merge results.

### Preparation

```bash
mkdir -p /tmp/uas-chunks
split -l 1000 data/large.csv /tmp/uas-chunks/chunk_
```

### Generate tasks dynamically

```bash
# gen_tasks.sh — create tasks.jsonl from chunks
for chunk in /tmp/uas-chunks/chunk_*; do
  id=$(basename "$chunk")
  echo "{\"id\":\"$id\",\"cmd\":\"python3 transform.py $chunk\",\"deps\":[],\"priority\":5,\"timeout\":120}"
done > tasks/process_data.jsonl
```

### Merge hook

```bash
#!/bin/bash
# hooks/merge_results.sh
RESULTS_DIR=$(dirname "$1")
head -1 "$RESULTS_DIR"/chunk_aa.out > merged.csv
for f in "$RESULTS_DIR"/*.out; do
  tail -n +2 "$f" >> merged.csv
done
echo "Merged $(wc -l < merged.csv) rows"
```

---

## Template 4: Build & Validate

Compile → Test → Quality Gate → Deploy.

### tasks.jsonl (DAG)

```json
{"id":"build","cmd":"cd /tmp/project && npm run build 2>&1","deps":[],"priority":10,"timeout":120}
{"id":"test","cmd":"cd /tmp/project && npm test 2>&1","deps":["build"],"priority":8,"timeout":180}
{"id":"lint","cmd":"cd /tmp/project && npm run lint 2>&1","deps":["build"],"priority":5,"timeout":60}
{"id":"deploy","cmd":"cd /tmp/project && npm run deploy 2>&1","deps":["test","lint"],"priority":3,"timeout":60}
```

### Quality gate hook

```bash
#!/bin/bash
# hooks/quality_gate.sh
if grep -q "FAIL\|Error\|failed" "$1"; then
  echo "Quality gate: BLOCKED — failures detected"
  exit 1
fi
echo "Quality gate: PASS"
```

---

## Template 5: Document Generation

Outline → Parallel Section Writing → Merge → Review Hook.

### tasks.jsonl

```json
{"id":"intro","cmd":"python3 write_section.py --section intro --outline outline.md","deps":[],"priority":5,"timeout":120}
{"id":"methods","cmd":"python3 write_section.py --section methods --outline outline.md","deps":[],"priority":5,"timeout":120}
{"id":"results","cmd":"python3 write_section.py --section results --outline outline.md","deps":[],"priority":5,"timeout":120}
{"id":"conclusion","cmd":"python3 write_section.py --section conclusion --outline outline.md","deps":[],"priority":5,"timeout":120}
{"id":"merge","cmd":"for s in intro methods results conclusion; do cat results/${s}.out; echo ''; done > final_document.md","deps":["intro","methods","results","conclusion"],"priority":3,"timeout":30}
```

### Review hook

```bash
#!/bin/bash
# hooks/review_doc.sh
FILE=$1
WORDS=$(wc -w < "$FILE")
if [ "$WORDS" -lt 500 ]; then
  echo "Document too short ($WORDS words)"
  exit 1
fi
for section in "Introduction" "Methods" "Results" "Conclusion"; do
  if ! grep -qi "$section" "$FILE"; then
    echo "Missing section: $section"
    exit 1
  fi
done
echo "Review: PASS ($WORDS words, all sections present)"
```

---

## Template 6: Multi-Source Data Aggregation

Fetch from multiple APIs/sources in parallel → normalize → merge.

### tasks.jsonl

```json
{"id":"source_a","cmd":"curl -s 'https://api.example.com/data' | python3 normalize.py --schema unified","deps":[],"priority":5,"timeout":60}
{"id":"source_b","cmd":"python3 scrape_source_b.py | python3 normalize.py --schema unified","deps":[],"priority":5,"timeout":60}
{"id":"source_c","cmd":"cat local_data.csv | python3 normalize.py --schema unified","deps":[],"priority":5,"timeout":30}
{"id":"merge","cmd":"python3 merge_sources.py source_a.out source_b.out source_c.out > aggregated.json","deps":["source_a","source_b","source_c"],"priority":3,"timeout":30}
```

---

## Template 7: Deep Research Swarm

Parallel search across multiple sources → extract findings → cross-validate → synthesize.

### tasks.jsonl

```json
{"id":"search_1","cmd":"python3 search.py --source arxiv --query '$QUERY' --max 10","deps":[],"priority":7,"timeout":90}
{"id":"search_2","cmd":"python3 search.py --source scholar --query '$QUERY' --max 10","deps":[],"priority":7,"timeout":90}
{"id":"search_3","cmd":"python3 search.py --source web --query '$QUERY' --max 10","deps":[],"priority":5,"timeout":90}
{"id":"extract_1","cmd":"python3 extract.py search_1.out --format structured","deps":["search_1"],"priority":5,"timeout":60}
{"id":"extract_2","cmd":"python3 extract.py search_2.out --format structured","deps":["search_2"],"priority":5,"timeout":60}
{"id":"extract_3","cmd":"python3 extract.py search_3.out --format structured","deps":["search_3"],"priority":5,"timeout":60}
{"id":"validate","cmd":"python3 cross_validate.py extract_1.out extract_2.out extract_3.out","deps":["extract_1","extract_2","extract_3"],"priority":8,"timeout":120}
{"id":"synthesize","cmd":"python3 synthesize.py validate.out --format report","deps":["validate"],"priority":10,"timeout":120}
```

Wave 0: 3 parallel searches → Wave 1: 3 parallel extractions → Wave 2: cross-validate → Wave 3: synthesize

---

## Template 8: Codebase Refactor with Test Gates

Dependency-ordered module rewrites where each module is tested before downstream modules proceed.

### tasks.jsonl

```json
{"id":"analyze","cmd":"python3 analyze_deps.py src/ > dep_map.json","deps":[],"priority":10,"timeout":60,"desc":"Map module dependencies"}
{"id":"refactor_utils","cmd":"python3 refactor.py src/utils.py --style modern","deps":["analyze"],"priority":8,"timeout":120}
{"id":"test_utils","cmd":"python3 -m pytest tests/test_utils.py -v 2>&1","deps":["refactor_utils"],"priority":9,"timeout":60}
{"id":"refactor_core","cmd":"python3 refactor.py src/core.py --style modern","deps":["test_utils"],"priority":8,"timeout":120}
{"id":"test_core","cmd":"python3 -m pytest tests/test_core.py -v 2>&1","deps":["refactor_core"],"priority":9,"timeout":60}
{"id":"refactor_api","cmd":"python3 refactor.py src/api.py --style modern","deps":["test_core"],"priority":8,"timeout":120}
{"id":"test_all","cmd":"python3 -m pytest tests/ -v 2>&1","deps":["refactor_api"],"priority":10,"timeout":180,"desc":"Full regression"}
```

Each module is refactored and tested before dependent modules proceed. Failure at any test gate blocks downstream work.

---

## Composing Templates

Templates are composable. Use DAG dependencies to chain patterns:

```json
{"id":"aggregate","cmd":"bash run_template6.sh","deps":[],"desc":"Multi-source fetch"}
{"id":"transform","cmd":"bash run_template3.sh aggregated.json","deps":["aggregate"],"desc":"Parallel transform"}
{"id":"report","cmd":"bash run_template5.sh transformed.csv","deps":["transform"],"desc":"Generate report"}
```

Add `--checkpoint` flag to orchestrate.sh for long composite workflows.
