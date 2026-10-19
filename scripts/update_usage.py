#!/usr/bin/env python3
"""Initialize or update ~/.ai_meter_usage.json for AIMeter."""

import datetime
import json
from pathlib import Path


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
        target_path.write_text(
            json.dumps(initial_data, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        print(f"[AIMeter] Initialized {target_path}:")
        print(json.dumps(initial_data, indent=2, ensure_ascii=False))
    else:
        try:
            current_data = json.loads(target_path.read_text(encoding="utf-8"))
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
        target_path.write_text(
            json.dumps(current_data, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        print(f"[AIMeter] Loaded and updated timestamp in {target_path}:")
        print(json.dumps(current_data, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
