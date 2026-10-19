#!/usr/bin/env python3
"""Initialize or atomically update ~/.ai_meter_usage.json for AIMeter."""

import datetime
import json
import os
from pathlib import Path
import tempfile


def atomic_write_json(target_path: Path, data: dict) -> None:
    content = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    parent_dir = target_path.parent
    fd, tmp_path_str = tempfile.mkstemp(
        prefix=".ai_meter_usage.", suffix=".tmp", dir=str(parent_dir)
    )
    tmp_path = Path(tmp_path_str)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(str(tmp_path), str(target_path))
        os.chmod(str(target_path), 0o600)
    except Exception:
        if tmp_path.exists():
            tmp_path.unlink(missing_ok=True)
        raise


def main() -> None:
    target_path = Path.home() / ".ai_meter_usage.json"

    if not target_path.exists():
        initial_data = {
            "openaiUsedTokens": 640000,
            "openaiCostUSD": 3.20,
            "geminiUsedTokens": 1250000,
            "geminiCostUSD": 1.85,
            "updatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }
        atomic_write_json(target_path, initial_data)
        print(f"[AIMeter] Initialized {target_path} (mode 0600):")
        print(json.dumps(initial_data, indent=2, ensure_ascii=False))
    else:
        try:
            current_data = json.loads(target_path.read_text(encoding="utf-8"))
            if not isinstance(current_data, dict):
                raise ValueError("Root JSON must be an object")
        except Exception:
            current_data = {
                "openaiUsedTokens": 640000,
                "openaiCostUSD": 3.20,
                "geminiUsedTokens": 1250000,
                "geminiCostUSD": 1.85,
            }
        current_data["updatedAt"] = datetime.datetime.now(
            datetime.timezone.utc
        ).isoformat()
        atomic_write_json(target_path, current_data)
        print(f"[AIMeter] Atomically updated {target_path} (mode 0600):")
        print(json.dumps(current_data, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
