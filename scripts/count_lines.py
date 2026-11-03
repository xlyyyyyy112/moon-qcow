"""Count owned MoonBit code; excludes tests, interfaces, dependencies and builds."""
from pathlib import Path
import json

root = Path(__file__).resolve().parents[1]
production = tests = physical = examples = 0
details = []
for path in sorted(root.rglob("*.mbt")):
    if any(part in {".mooncakes", "_build", "target", ".git"} for part in path.relative_to(root).parts):
        continue
    lines = path.read_text(encoding="utf-8").splitlines()
    effective = sum(bool(line.strip()) and not line.lstrip().startswith("//") for line in lines)
    is_test = path.name.endswith(("_test.mbt", "_wbtest.mbt"))
    if is_test:
        tests += effective
    else:
        production += effective
        physical += len(lines)
        if path.relative_to(root).parts[0] == "examples":
            examples += effective
    details.append({"file":path.relative_to(root).as_posix(), "effective":effective, "test":is_test})
print(json.dumps({"production_effective":production, "production_physical":physical,
                  "implementation_without_examples":production-examples,
                  "examples_effective":examples,
                  "tests_effective":tests, "files":details}, ensure_ascii=False, indent=2))
