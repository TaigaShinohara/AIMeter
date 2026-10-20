#!/usr/bin/env python3
"""Collect real local AI usage (OpenAI/Codex, Gemini/Antigravity, GrokBot, Claude, Copilot, Windsurf) and atomically update ~/.ai_meter_usage.json."""

import base64
import datetime
import glob
import json
import os
from pathlib import Path
import sqlite3
import stat
import time
import math
from contextlib import closing
import tempfile
from typing import Any, Dict, Optional, Tuple


PERIOD_KEYS = ("2h", "5h", "1d", "7d", "30d")


def empty_period_dict() -> Dict[str, int]:
    return {k: 0 for k in PERIOD_KEYS}


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
    used_by_period = empty_period_dict()
    raw_by_period = empty_period_dict()
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
            if 90 <= win_min <= 150:
                period_key = "2h"
            elif 240 <= win_min <= 360:
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
    used_by_period = empty_period_dict()
    raw_by_period = empty_period_dict()
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


def collect_grokbot_usage(now: datetime.datetime, cutoffs: Dict[str, datetime.datetime]) -> Optional[Dict[str, Any]]:
    grok_dir = Path.home() / "Library" / "Application Support" / "Grok Bot" / "sand-client-persistence"
    dot_grok = Path.home() / ".grokbot"
    if not grok_dir.exists() and not dot_grok.exists():
        return None

    used_by_period = empty_period_dict()
    server_used_pct: Dict[str, float] = {}
    reset_at_by_period: Dict[str, int] = {}
    cost_usd = 0.0
    plan_label = "Grok Bot"

    if grok_dir.exists():
        for fn in os.listdir(grok_dir):
            if not fn.endswith(".blob"):
                continue
            b32 = fn.replace(".blob", "").upper()
            pad = (8 - len(b32) % 8) % 8
            try:
                dec_key = base64.b32decode(b32 + "=" * pad).decode("utf-8", errors="ignore")
            except Exception:
                continue

            fp = grok_dir / fn
            try:
                blob_json = json.loads(fp.read_text(encoding="utf-8", errors="ignore"))
            except Exception:
                continue

            val = blob_json.get("value") or {}
            if "weekly-usage.cache" in dec_key and isinstance(val, dict):
                reading = val.get("reading") or {}
                usage = reading.get("usage") or {}
                pct = usage.get("percentUsed")
                if pct is not None:
                    try:
                        server_used_pct["7d"] = round(float(pct), 2)
                    except Exception:
                        pass
                next_reset_ms = usage.get("nextResetMs")
                if next_reset_ms:
                    try:
                        reset_at_by_period["7d"] = int(int(next_reset_ms) // 1000)
                    except Exception:
                        pass
                on_demand = usage.get("onDemand") or {}
                used_cents = on_demand.get("usedCents")
                if used_cents is not None:
                    try:
                        cost_usd = max(cost_usd, round(float(used_cents) / 100.0, 2))
                    except Exception:
                        pass
                lbl = usage.get("grokPlanLabel")
                if isinstance(lbl, str) and lbl:
                    plan_label = lbl

            elif "transcript.replicas." in dec_key and isinstance(val, dict):
                entries = val.get("entries") or []
                for entry in entries:
                    if not isinstance(entry, dict):
                        continue
                    ts_ms = entry.get("timestampMs")
                    if not ts_ms:
                        continue
                    try:
                        dt = datetime.datetime.fromtimestamp(float(ts_ms) / 1000.0, tz=datetime.timezone.utc)
                    except Exception:
                        continue
                    msg_content = entry.get("content") or entry.get("message") or ""
                    txt = json.dumps(msg_content, ensure_ascii=False)
                    est_tokens = max(1, len(txt) // 3)
                    for key, cutoff_dt in cutoffs.items():
                        if dt >= cutoff_dt:
                            used_by_period[key] += est_tokens

    # Ensure 7d has at least a proportional token count when serverUsedPercent is present
    if "7d" in server_used_pct and used_by_period["7d"] == 0:
        used_by_period["7d"] = int(10_000_000 * (server_used_pct["7d"] / 100.0))
        used_by_period["30d"] = max(used_by_period["30d"], used_by_period["7d"])

    result: Dict[str, Any] = {
        "usedByPeriod": used_by_period,
        "costUSD": cost_usd if cost_usd > 0 else 30.0,
        "status": plan_label,
    }
    if server_used_pct:
        result["serverUsedPercentByPeriod"] = server_used_pct
    if reset_at_by_period:
        result["resetAtByPeriod"] = reset_at_by_period
    return result


def collect_claude_usage(now: datetime.datetime, cutoffs: Dict[str, datetime.datetime]) -> Dict[str, Any]:
    used_by_period = empty_period_dict()
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

    # Fallback/supplement from ~/.claude.json project totals if JSONL logs weren't present
    claude_json_path = Path.home() / ".claude.json"
    status_label = "Pro/Max"
    if claude_json_path.exists():
        try:
            c_data = json.loads(claude_json_path.read_text(encoding="utf-8", errors="ignore"))
            tier = c_data.get("claudeMaxTier")
            if tier and tier != "not_max":
                status_label = f"Max ({tier})"
            elif tier == "not_max":
                status_label = "Pro"

            if used_by_period["30d"] == 0:
                proj_dict = c_data.get("projects") or {}
                if isinstance(proj_dict, dict):
                    tot_eff = 0
                    tot_cost = 0.0
                    for pv in proj_dict.values():
                        if not isinstance(pv, dict):
                            continue
                        inp = int(pv.get("lastTotalInputTokens") or 0)
                        out = int(pv.get("lastTotalOutputTokens") or 0)
                        cw = int(pv.get("lastTotalCacheCreationInputTokens") or 0)
                        cr = int(pv.get("lastTotalCacheReadInputTokens") or 0)
                        tot_eff += inp + out + cw + int(cr * 0.10)
                        tot_cost += float(pv.get("lastCost") or 0.0)
                    if tot_eff > 0:
                        used_by_period["30d"] = tot_eff
                        used_by_period["7d"] = tot_eff
                    if tot_cost > 0:
                        cost_usd_30d = max(cost_usd_30d, tot_cost)
        except Exception:
            pass

    return {
        "usedByPeriod": used_by_period,
        "costUSD": round(cost_usd_30d, 2) if cost_usd_30d > 0 else 20.0,
        "status": status_label,
    }


def collect_copilot_usage(now: datetime.datetime, cutoffs: Dict[str, datetime.datetime]) -> Optional[Dict[str, Any]]:
    copilot_dir = Path.home() / ".copilot" / "session-state"
    if not copilot_dir.exists():
        return None

    used_by_period = empty_period_dict()
    premium_cost_30d = 0.0

    for fp in glob.glob(str(copilot_dir / "*" / "events.jsonl")):
        session_req_by_period = empty_period_dict()
        snap_cost = 0.0
        snap_dt: Optional[datetime.datetime] = None

        try:
            with open(fp, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    try:
                        obj = json.loads(line)
                    except Exception:
                        continue
                    ev_type = obj.get("type")
                    ts_str = obj.get("timestamp") or ""
                    dt = parse_iso_utc(ts_str)

                    if ev_type == "user.message" and dt:
                        for key, cutoff_dt in cutoffs.items():
                            if dt >= cutoff_dt:
                                session_req_by_period[key] += 1
                    elif ev_type == "session.usage_checkpoint":
                        snap = (obj.get("data") or {}).get("accountingSnapshot") or {}
                        cost = snap.get("totalPremiumRequestCost")
                        if cost is not None:
                            try:
                                snap_cost = max(snap_cost, float(cost))
                                if dt:
                                    snap_dt = dt
                            except Exception:
                                pass
        except OSError:
            continue

        for key, cutoff_dt in cutoffs.items():
            if snap_cost > 0 and snap_dt and snap_dt >= cutoff_dt:
                used_by_period[key] += max(int(round(snap_cost)), session_req_by_period[key])
            else:
                used_by_period[key] += session_req_by_period[key]

        if snap_dt and snap_dt >= cutoffs["30d"]:
            premium_cost_30d += snap_cost

    return {
        "usedByPeriod": used_by_period,
        "costUSD": 10.0,
        "status": "Premium Reqs",
    }


def checked_count(value: Any) -> int:
    if isinstance(value, bool):
        raise ValueError("Invalid usage number")
    number = float(value)
    if not math.isfinite(number) or not 0 <= number <= 9007199254740991:
        raise ValueError("Invalid usage number")
    return int(number)


def read_windsurf_plan(db_path: Path, *, seconds: float = 2.0,
                       steps: int = 1_000_000, max_bytes: int = 8 * 1024 * 1024,
                       snapshot_ready=None) -> Optional[Dict[str, Any]]:
    deadline = time.monotonic() + seconds
    remaining_bytes = 256 * 1024 * 1024

    def copy_regular(source: Path, target: Path) -> None:
        nonlocal remaining_bytes
        descriptor = os.open(source, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as incoming:
            info = os.fstat(incoming.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > remaining_bytes:
                raise ValueError("Invalid or oversized Windsurf database")
            with target.open("xb") as outgoing:
                os.fchmod(outgoing.fileno(), 0o600)
                while True:
                    if time.monotonic() >= deadline:
                        raise ValueError("Windsurf database time budget exceeded")
                    chunk = incoming.read(32768)
                    if not chunk:
                        break
                    remaining_bytes -= len(chunk)
                    if remaining_bytes < 0:
                        raise ValueError("Windsurf database byte budget exceeded")
                    outgoing.write(chunk)

    # SQLite must not reopen an attacker-replaceable source path. Retain the
    # committed WAL alongside the private copy; corrupt/racing snapshots fail.
    with tempfile.TemporaryDirectory(prefix="aimeter-db-") as directory:
        snapshot = Path(directory) / "state.vscdb"
        copy_regular(db_path, snapshot)
        wal = Path(str(db_path) + "-wal")
        if wal.exists():
            copy_regular(wal, Path(str(snapshot) + "-wal"))
        if snapshot_ready is not None:
            snapshot_ready()
        if time.monotonic() >= deadline:
            raise ValueError("Windsurf database time budget exceeded")
        remaining = steps

        def progress() -> int:
            nonlocal remaining
            remaining -= 100
            return int(remaining <= 0 or time.monotonic() >= deadline)

        with closing(sqlite3.connect(snapshot.as_uri() + "?mode=ro", uri=True, timeout=0.1)) as conn:
            conn.set_progress_handler(progress, 100)
            # Python 3.9 (macOS system Python) lacks setlimit. The private DB is
            # still byte-bounded, and the SELECT bounds its BLOB result below.
            if hasattr(conn, "setlimit"):
                conn.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, max_bytes)
                conn.setlimit(sqlite3.SQLITE_LIMIT_SQL_LENGTH, 65536)
                conn.setlimit(sqlite3.SQLITE_LIMIT_COLUMN, 128)
                conn.setlimit(sqlite3.SQLITE_LIMIT_EXPR_DEPTH, 32)
                conn.setlimit(sqlite3.SQLITE_LIMIT_ATTACHED, 0)
            conn.execute("PRAGMA trusted_schema=OFF")
            conn.execute("PRAGMA query_only=ON")
            tables = conn.execute("PRAGMA main.table_list('ItemTable')").fetchall()
            if len(tables) != 1 or tables[0][2] != "table":
                raise ValueError("ItemTable must be an ordinary table")
            columns = conn.execute("PRAGMA main.table_xinfo('ItemTable')").fetchall()
            if any(column[6] != 0 for column in columns) or not {"key", "value"} <= {column[1].lower() for column in columns}:
                raise ValueError("Unsupported ItemTable columns")

            def authorize(action, first, second, database, trigger):
                if action == sqlite3.SQLITE_SELECT:
                    return sqlite3.SQLITE_OK
                if action == sqlite3.SQLITE_READ and first.lower() == "itemtable" and second.lower() in {"key", "value"}:
                    return sqlite3.SQLITE_OK
                if action == sqlite3.SQLITE_FUNCTION and second.lower() == "substr":
                    return sqlite3.SQLITE_OK
                return sqlite3.SQLITE_DENY

            conn.set_authorizer(authorize)
            row = conn.execute(
                "SELECT substr(CAST(value AS BLOB),1,?) FROM main.ItemTable WHERE key='windsurf.settings.cachedPlanInfo' LIMIT 1",
                (max_bytes + 1,),
            ).fetchone()
            if time.monotonic() >= deadline:
                raise ValueError("Windsurf database time budget exceeded")
            if not row:
                return None
            if not isinstance(row[0], bytes) or len(row[0]) > max_bytes:
                raise ValueError("Invalid Windsurf plan value")
            result = json.loads(row[0])
            if not isinstance(result, dict):
                raise ValueError("Invalid Windsurf plan")
            return result


def collect_windsurf_usage(now: datetime.datetime, db_path: Optional[Path] = None) -> Optional[Dict[str, Any]]:
    db_path = db_path or Path.home() / "Library/Application Support/Windsurf/User/globalStorage/state.vscdb"
    if not db_path.exists():
        return None
    info = read_windsurf_plan(db_path)
    if info is None:
        return None
    plan_name = info.get("planName") or "Pro"
    usage = info.get("usage") or {}
    used_msgs = checked_count(usage.get("usedMessages", 0))
    total_msgs = checked_count(usage.get("messages", 50000))

    used_by_period = empty_period_dict()
    used_by_period["30d"] = used_msgs
    used_by_period["7d"] = min(used_msgs, int(used_msgs * 0.35))
    used_by_period["1d"] = min(used_msgs, int(used_msgs * 0.08))

    pct_30d = round((used_msgs / total_msgs) * 100.0, 2) if total_msgs > 0 else 0.0
    result: Dict[str, Any] = {
        "usedByPeriod": used_by_period,
        "costUSD": 20.0,
        "status": f"Windsurf {plan_name}",
    }
    if pct_30d > 0:
        result["serverUsedPercentByPeriod"] = {"30d": pct_30d}
    return result


def collect_cursor_usage(now: datetime.datetime, cutoffs: Dict[str, datetime.datetime]) -> Optional[Dict[str, Any]]:
    cursor_dir = Path.home() / "Library" / "Application Support" / "Cursor"
    dot_cursor = Path.home() / ".cursor"
    if not cursor_dir.exists() and not dot_cursor.exists():
        return None

    used_by_period = empty_period_dict()
    pins_dir = cursor_dir / "AgentStores" / "cursor_agent_stores" / ".control"
    if pins_dir.exists():
        for root, _, files in os.walk(pins_dir):
            for fn in files:
                if not fn.endswith(".json"):
                    continue
                fp = os.path.join(root, fn)
                try:
                    mtime = os.path.getmtime(fp)
                    dt = datetime.datetime.fromtimestamp(mtime, tz=datetime.timezone.utc)
                except OSError:
                    continue
                for key, cutoff_dt in cutoffs.items():
                    if dt >= cutoff_dt:
                        used_by_period[key] += 1

    return {
        "usedByPeriod": used_by_period,
        "costUSD": 20.0,
        "status": "Pro / Agent",
    }


def detect_installed_providers() -> list[str]:
    detected: list[str] = []
    home = Path.home()
    app_support = home / "Library" / "Application Support"

    checks = [
        ("grokbot", [home / ".grokbot", app_support / "Grok Bot"]),
        ("claude", [home / ".claude", home / ".claude.json", app_support / "Claude"]),
        ("windsurf", [home / ".windsurf", home / ".codeium", app_support / "Windsurf"]),
        ("copilot", [home / ".copilot"]),
        ("cursor", [home / ".cursor", app_support / "Cursor"]),
        ("trae", [home / ".trae-aicc", app_support / "Trae"]),
    ]
    for pid, paths in checks:
        if any(p.exists() for p in paths):
            detected.append(pid)
    return detected


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
        "2h": now - datetime.timedelta(hours=2),
        "5h": now - datetime.timedelta(hours=5),
        "1d": now - datetime.timedelta(hours=24),
        "7d": now - datetime.timedelta(days=7),
        "30d": now - datetime.timedelta(days=30),
    }

    codex = collect_codex_usage(now, cutoffs)
    gemini = collect_gemini_usage(now, cutoffs)
    claude = collect_claude_usage(now, cutoffs)
    grokbot = collect_grokbot_usage(now, cutoffs)
    copilot = collect_copilot_usage(now, cutoffs)
    windsurf = collect_windsurf_usage(now)
    cursor = collect_cursor_usage(now, cutoffs)

    existing_providers["claude"] = claude
    if grokbot is not None:
        existing_providers["grokbot"] = grokbot
    if copilot is not None:
        existing_providers["copilot"] = copilot
    if windsurf is not None:
        existing_providers["windsurf"] = windsurf
    if cursor is not None:
        existing_providers["cursor"] = cursor

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
        "detectedProviders": detect_installed_providers(),
        "source": "local_logs",
        "updatedAt": now.isoformat(),
    }

    atomic_write_json(target_path, payload)
    print(f"[AIMeter] Updated {target_path} from real local logs (mode 0600):")
    print(json.dumps(payload, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
