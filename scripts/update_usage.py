#!/usr/bin/env python3
"""Collect real local AI usage (OpenAI/Codex, Gemini/Antigravity, Claude) and atomically update ~/.ai_meter_usage.json."""

import datetime
import glob
import json
import os
from pathlib import Path
import tempfile
from typing import Any, Dict, Optional, Tuple


def atomic_write_json(target_path: Path, data: Dict[str, Any]) -> None:
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


def parse_iso_utc(ts_str: str) -> Optional[datetime.datetime]:
    if not ts_str:
        return None
    try:
        dt = datetime.datetime.fromisoformat(ts_str.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt
    except Exception:
        return None


def collect_codex_usage(now: datetime.datetime, cutoffs: Dict[str, datetime.datetime]) -> Dict[str, Any]:
    used_by_period = {"5h": 0, "1d": 0, "7d": 0, "30d": 0}
    raw_by_period = {"5h": 0, "1d": 0, "7d": 0, "30d": 0}
    cost_usd_30d = 0.0
    latest_rl: Optional[Dict[str, Any]] = None
    latest_rl_ts = ""
    cutoff_30d_epoch = cutoffs["30d"].timestamp()

    session_pattern = str(Path.home() / ".codex" / "sessions" / "*" / "*" / "*" / "*.jsonl")
    for fp in glob.glob(session_pattern):
        try:
            if os.path.getmtime(fp) < cutoff_30d_epoch:
                continue
        except OSError:
            continue

        prev_tuple: Optional[Tuple[int, int, int]] = None
        try:
            with open(fp, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    if '"token_count"' not in line:
                        continue
                    try:
                        obj = json.loads(line)
                    except Exception:
                        continue
                    payload = obj.get("payload") or {}
                    if payload.get("type") != "token_count":
                        continue

                    ts_str = obj.get("timestamp") or ""
                    rl = payload.get("rate_limits")
                    if rl and ts_str > latest_rl_ts:
                        latest_rl_ts = ts_str
                        latest_rl = rl

                    info = payload.get("info") or {}
                    tot_usage = info.get("total_token_usage")
                    if not tot_usage or not ts_str:
                        continue

                    cur_in = int(tot_usage.get("input_tokens") or 0)
                    cur_cached = int(tot_usage.get("cached_input_tokens") or 0)
                    cur_out = int(tot_usage.get("output_tokens") or 0)
                    cur_tuple = (cur_in, cur_cached, cur_out)

                    if prev_tuple is None:
                        d_in, d_cached, d_out = cur_in, cur_cached, cur_out
                    else:
                        if cur_tuple == prev_tuple:
                            continue
                        d_in = max(0, cur_in - prev_tuple[0])
                        d_cached = max(0, cur_cached - prev_tuple[1])
                        d_out = max(0, cur_out - prev_tuple[2])
                    prev_tuple = cur_tuple

                    dt = parse_iso_utc(ts_str)
                    if not dt:
                        continue

                    uncached_in = max(0, d_in - d_cached)
                    effective_tokens = uncached_in + d_out + int(d_cached * 0.10)
                    raw_tokens = d_in + d_out

                    for key, cutoff_dt in cutoffs.items():
                        if dt >= cutoff_dt:
                            used_by_period[key] += effective_tokens
                            raw_by_period[key] += raw_tokens

                    if dt >= cutoffs["30d"]:
                        cost_usd_30d += (
                            uncached_in * 2.50 + d_cached * 0.25 + d_out * 10.0
                        ) / 1_000_000.0
        except OSError:
            continue

    server_used_pct: Dict[str, float] = {}
    reset_at_by_period: Dict[str, int] = {}
    plan_type: Optional[str] = None
    credit_balance: Optional[float] = None

    if latest_rl:
        plan_type = latest_rl.get("plan_type")
        credits = latest_rl.get("credits") or {}
        if credits.get("balance") is not None:
            try:
                credit_balance = round(float(credits["balance"]), 2)
            except Exception:
                pass

        for slot_key in ("primary", "secondary"):
            slot = latest_rl.get(slot_key)
            if not isinstance(slot, dict):
                continue
            win_min = int(slot.get("window_minutes") or 0)
            used_pct = slot.get("used_percent")
            resets_at = slot.get("resets_at")
            period_key: Optional[str] = None
            if 240 <= win_min <= 360:
                period_key = "5h"
            elif 1380 <= win_min <= 1500:
                period_key = "1d"
            elif 9500 <= win_min <= 10500:
                period_key = "7d"
            elif win_min > 40000:
                period_key = "30d"

            if period_key and used_pct is not None:
                try:
                    server_used_pct[period_key] = float(used_pct)
                except Exception:
                    pass
            if period_key and resets_at is not None:
                try:
                    reset_at_by_period[period_key] = int(resets_at)
                except Exception:
                    pass

    return {
        "used_by_period": used_by_period,
        "raw_by_period": raw_by_period,
        "cost_usd_30d": round(cost_usd_30d, 2),
        "server_used_pct": server_used_pct,
        "reset_at_by_period": reset_at_by_period,
        "plan_type": plan_type,
        "credit_balance": credit_balance,
    }


def collect_gemini_usage(now: datetime.datetime, cutoffs: Dict[str, datetime.datetime]) -> Dict[str, Any]:
    used_by_period = {"5h": 0, "1d": 0, "7d": 0, "30d": 0}
    raw_by_period = {"5h": 0, "1d": 0, "7d": 0, "30d": 0}
    cost_usd_30d = 0.0
    cutoff_30d_epoch = cutoffs["30d"].timestamp()

    ag_pattern = str(
        Path.home()
        / ".gemini"
        / "antigravity"
        / "brain"
        / "*"
        / ".system_generated"
        / "logs"
        / "transcript.jsonl"
    )
    for fp in glob.glob(ag_pattern):
        try:
            if os.path.getmtime(fp) < cutoff_30d_epoch:
                continue
        except OSError:
            continue

        try:
            with open(fp, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    if "created_at" not in line:
                        continue
                    try:
                        obj = json.loads(line)
                    except Exception:
                        continue
                    dt = parse_iso_utc(obj.get("created_at") or "")
                    if not dt:
                        continue

                    inp = int(obj.get("input_tokens") or 0)
                    cached = int(obj.get("cache_read_tokens") or 0)
                    out = int(obj.get("output_tokens") or 0)

                    if inp + cached + out > 0:
                        effective = inp + out + int(cached * 0.10)
                        raw_tot = inp + cached + out
                        step_cost = (inp * 1.25 + cached * 0.3125 + out * 5.0) / 1_000_000.0
                    else:
                        content_str = str(obj.get("content") or "") + str(obj.get("thinking") or "")
                        est_tokens = max(1, len(content_str) // 4)
                        effective = est_tokens
                        raw_tot = est_tokens
                        step_cost = (est_tokens * 2.0) / 1_000_000.0

                    for key, cutoff_dt in cutoffs.items():
                        if dt >= cutoff_dt:
                            used_by_period[key] += effective
                            raw_by_period[key] += raw_tot

                    if dt >= cutoffs["30d"]:
                        cost_usd_30d += step_cost
        except OSError:
            continue

    chats_pattern = str(Path.home() / ".gemini" / "tmp" / "*" / "chats" / "*.json")
    for fp in glob.glob(chats_pattern):
        try:
            if os.path.getmtime(fp) < cutoff_30d_epoch:
                continue
            data = json.loads(Path(fp).read_text(encoding="utf-8", errors="ignore"))
            for msg in data.get("messages", []):
                dt = parse_iso_utc(msg.get("timestamp") or "")
                tokens = msg.get("tokens") or {}
                if not dt or not tokens:
                    continue
                tot = int(tokens.get("total") or 0)
                cached = int(tokens.get("cached") or 0)
                out = int(tokens.get("output") or 0)
                uncached_in = max(0, int(tokens.get("input") or 0) - cached)
                effective = uncached_in + out + int(cached * 0.10)

                for key, cutoff_dt in cutoffs.items():
                    if dt >= cutoff_dt:
                        used_by_period[key] += effective
                        raw_by_period[key] += tot

                if dt >= cutoffs["30d"]:
                    cost_usd_30d += (uncached_in * 1.25 + cached * 0.3125 + out * 5.0) / 1_000_000.0
        except Exception:
            continue

    return {
        "used_by_period": used_by_period,
        "raw_by_period": raw_by_period,
        "cost_usd_30d": round(cost_usd_30d, 2),
    }


def collect_claude_usage(now: datetime.datetime, cutoffs: Dict[str, datetime.datetime]) -> Dict[str, Any]:
    used_by_period = {"5h": 0, "1d": 0, "7d": 0, "30d": 0}
    cost_usd_30d = 0.0
    cutoff_30d_epoch = cutoffs["30d"].timestamp()

    patterns = [
        str(Path.home() / ".claude" / "projects" / "**" / "*.jsonl"),
        str(Path.home() / ".claude" / "sessions" / "**" / "*.jsonl"),
    ]
    for pat in patterns:
        for fp in glob.glob(pat, recursive=True):
            try:
                if os.path.getmtime(fp) < cutoff_30d_epoch:
                    continue
                with open(fp, "r", encoding="utf-8", errors="ignore") as f:
                    for line in f:
                        if "usage" not in line:
                            continue
                        try:
                            obj = json.loads(line)
                        except Exception:
                            continue
                        dt = parse_iso_utc(obj.get("timestamp") or obj.get("createdAt") or "")
                        msg = obj.get("message") or {}
                        usage = msg.get("usage") or obj.get("usage") or {}
                        if not dt or not isinstance(usage, dict):
                            continue
                        inp = int(usage.get("input_tokens") or 0)
                        cached = int(usage.get("cache_read_input_tokens") or 0)
                        out = int(usage.get("output_tokens") or 0)
                        effective = inp + out + int(cached * 0.10)
                        if effective <= 0:
                            continue
                        for key, cutoff_dt in cutoffs.items():
                            if dt >= cutoff_dt:
                                used_by_period[key] += effective
                        if dt >= cutoffs["30d"]:
                            cost_usd_30d += (inp * 3.0 + cached * 0.30 + out * 15.0) / 1_000_000.0
            except Exception:
                continue

    return {
        "usedByPeriod": used_by_period,
        "costUSD": round(cost_usd_30d, 2),
    }


def main() -> None:
    target_path = Path.home() / ".ai_meter_usage.json"
    existing_providers: Dict[str, Any] = {}
    if target_path.exists():
        try:
            existing_json = json.loads(target_path.read_text(encoding="utf-8"))
            if isinstance(existing_json, dict) and isinstance(existing_json.get("providers"), dict):
                existing_providers = existing_json["providers"]
        except Exception:
            pass

    now = datetime.datetime.now(datetime.timezone.utc)
    cutoffs = {
        "5h": now - datetime.timedelta(hours=5),
        "1d": now - datetime.timedelta(hours=24),
        "7d": now - datetime.timedelta(days=7),
        "30d": now - datetime.timedelta(days=30),
    }

    codex = collect_codex_usage(now, cutoffs)
    gemini = collect_gemini_usage(now, cutoffs)
    claude = collect_claude_usage(now, cutoffs)

    if sum(claude["usedByPeriod"].values()) > 0 or "claude" not in existing_providers:
        existing_providers["claude"] = claude

    payload: Dict[str, Any] = {
        "openaiUsedTokens": codex["used_by_period"]["30d"],
        "openaiCostUSD": codex["cost_usd_30d"],
        "openaiUsedByPeriod": codex["used_by_period"],
        "openaiRawTokensByPeriod": codex["raw_by_period"],
        "openaiServerUsedPercentByPeriod": codex["server_used_pct"],
        "openaiResetAtByPeriod": codex["reset_at_by_period"],
        "openaiPlanType": codex["plan_type"],
        "openaiCreditBalance": codex["credit_balance"],
        "geminiUsedTokens": gemini["used_by_period"]["30d"],
        "geminiCostUSD": gemini["cost_usd_30d"],
        "geminiUsedByPeriod": gemini["used_by_period"],
        "geminiRawTokensByPeriod": gemini["raw_by_period"],
        "providers": existing_providers,
        "source": "local_logs",
        "updatedAt": now.isoformat(),
    }

    atomic_write_json(target_path, payload)
    print(f"[AIMeter] Updated {target_path} from real local logs (mode 0600):")
    print(json.dumps(payload, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
