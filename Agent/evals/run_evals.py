"""
Run the golden questions (golden_questions.yml) against the grocery value agent
and score the answers.

    python3 Agent/evals/run_evals.py                      # prod agent
    python3 Agent/evals/run_evals.py --sandbox            # sandbox agent + GROCERY_DEV_* checks
    python3 Agent/evals/run_evals.py --ids cmp_01,tim_01  # a subset

Auth: the same Snowflake connection the `snow` CLI uses (~/.snowflake/
connections.toml, default connection, or --connection NAME). The session
token from that connection calls the Cortex Agent REST API; no PAT needed.

Checks per question:
  contains        every phrase appears in the answer (case-insensitive)
  mentions_as_of  the answer names a date, week or "as of"
  declines        the answer is a short refusal (heuristic phrases)
  sql             the check query is run and an LLM judge (Cortex COMPLETE)
                  decides whether the answer agrees with its rows
A question passes when every check it has passes. Target: >= 90% overall.
Results are printed and written to Agent/evals/results_<timestamp>.json.
"""

import argparse
import json
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import requests
import snowflake.connector
import yaml

HERE = Path(__file__).resolve().parent
DB = "GROCERYDBTPROJECT"
JUDGE_MODEL = "llama3.1-70b"

DECLINE_PHRASES = [
    "can't forecast", "cannot forecast", "can't predict", "cannot predict", "limited to the next", "don't cover", "do not cover",
    "can't help", "cannot help", "not able to", "unable to", "outside", "only cover",
    "only covers", "don't have", "do not have", "not available", "beyond", "can't guarantee",
    "cannot guarantee", "isn't something", "not something", "i don't provide", "not covered",
]
AS_OF_RE = re.compile(r"(as of|week of|\b20\d\d-\d\d-\d\d\b|\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]* \d{1,2}\b)", re.I)


def connect(connection_name: str | None):
    kwargs = {"connection_name": connection_name} if connection_name else {}
    return snowflake.connector.connect(**kwargs)


def agent_url(conn, schema: str, agent: str) -> str:
    host = conn.host
    return f"https://{host}/api/v2/databases/{DB}/schemas/{schema}/agents/{agent}:run"


def ask_agent(conn, url: str, question: str, timeout: int = 180) -> tuple[str, list[str]]:
    """Returns (final answer text, tools used). Parses the SSE stream."""
    headers = {
        "Authorization": f'Snowflake Token="{conn.rest.token}"',
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
    }
    body = {"messages": [{"role": "user", "content": [{"type": "text", "text": question}]}]}
    deltas, fulls, tools = [], [], []
    with requests.post(url, headers=headers, json=body, stream=True, timeout=timeout) as r:
        r.raise_for_status()
        event = None
        for raw in r.iter_lines(decode_unicode=True):
            if not raw:
                continue
            if raw.startswith("event:"):
                event = raw[6:].strip()
            elif raw.startswith("data:"):
                payload = raw[5:].strip()
                if payload in ("", "[DONE]"):
                    continue
                try:
                    data = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                # the stream carries the text twice: as deltas and again as a
                # final response.text event — keep one or the other, never both
                if event == "response.text.delta":
                    deltas.append(data.get("text", ""))
                elif event == "response.text":
                    fulls.append(data.get("text", ""))
                elif event and event.startswith("response.tool_use"):
                    name = data.get("name") or data.get("tool_name") or data.get("type")
                    if name:
                        tools.append(name)
                elif event == "error":
                    fulls.append(f"[agent error] {data}")
    text = "".join(deltas).strip() or "".join(fulls).strip()
    return text, tools


def run_sql(conn, sql: str, limit: int = 12) -> list[dict]:
    cur = conn.cursor(snowflake.connector.DictCursor)
    cur.execute(sql)
    rows = cur.fetchmany(limit)
    return [{k: (str(v) if v is not None else None) for k, v in row.items()} for row in rows]


def judge(conn, question: str, answer: str, rows: list[dict], notes: str | None) -> tuple[bool, str]:
    prompt = (
        "You grade a grocery-price assistant. Question:\n" + question +
        "\n\nReference rows from the database (the truth):\n" + json.dumps(rows, indent=1)[:6000] +
        ("\n\nGrading notes: " + notes if notes else "") +
        "\n\nAssistant answer:\n" + answer[:6000] +
        "\n\nPASS if the answer is consistent with the reference rows on the facts it states (numbers within rounding; items it names appear "
        "in the data or are a reasonable different selection or grouping for the same question) and respects the grading notes. "
        "FAIL only if it contradicts the reference rows, invents facts, or omits what the notes require. The answer may cover more or "
        "fewer items than the reference and may group them differently; that alone is not a failure. "
        "Reply with PASS or FAIL on the first line, then one sentence why."
    )
    cur = conn.cursor()
    cur.execute("select snowflake.cortex.complete(%s, %s)", (JUDGE_MODEL, prompt))
    verdict = cur.fetchone()[0].strip()
    return verdict.upper().startswith("PASS"), verdict.splitlines()[-1][:200]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--sandbox", action="store_true", help="use the sandbox agent and GROCERY_DEV_* schemas in checks")
    ap.add_argument("--connection", help="connections.toml connection name (default: the default connection)")
    ap.add_argument("--ids", help="comma-separated question ids to run")
    ap.add_argument("--agent", default="GROCERY_VALUE_AGENT")
    args = ap.parse_args()

    schema = "GROCERY_DEV_SEMANTIC" if args.sandbox else "GROCERY_SEMANTIC"
    questions = yaml.safe_load((HERE / "golden_questions.yml").read_text())["questions"]
    if args.ids:
        wanted = set(args.ids.split(","))
        questions = [q for q in questions if q["id"] in wanted]

    conn = connect(args.connection)
    url = agent_url(conn, schema, args.agent)
    results, passed = [], 0
    for q in questions:
        t0 = time.time()
        try:
            answer, tools = ask_agent(conn, url, q["question"])
        except Exception as e:  # keep going; the failure is the result
            answer, tools = f"[request failed] {e}", []
        checks: dict[str, tuple[bool, str]] = {}
        low = answer.lower()
        if q.get("contains"):
            missing = [c for c in q["contains"] if c.lower() not in low]
            checks["contains"] = (not missing, f"missing {missing}" if missing else "ok")
        if q.get("mentions_as_of"):
            checks["as_of"] = (bool(AS_OF_RE.search(answer)), "ok" if AS_OF_RE.search(answer) else "no date/week")
        if q.get("declines"):
            # a refusal may add what the agent CAN say (current prices, as-of
            # data), so length is not a criterion — the refusal phrase is
            refused = any(p in low for p in DECLINE_PHRASES)
            checks["declines"] = (refused, "ok" if refused else "no refusal phrase")
        if q.get("sql"):
            try:
                sql = q["sql"]
                if args.sandbox:
                    sql = re.sub(r"GROCERY_(MARTS|SEMANTIC|RAW|ML)\.", r"GROCERY_DEV_\1.", sql)
                rows = run_sql(conn, sql)
                checks["sql"] = judge(conn, q["question"], answer, rows, q.get("notes"))
            except Exception as e:
                checks["sql"] = (False, f"check failed: {e}")
        ok = all(v[0] for v in checks.values()) if checks else bool(answer) and not answer.startswith("[")
        passed += ok
        results.append({"id": q["id"], "family": q["family"], "pass": ok, "tools": tools,
                        "checks": {k: {"pass": v[0], "why": v[1]} for k, v in checks.items()},
                        "seconds": round(time.time() - t0, 1), "answer": answer})
        print(f"{'PASS' if ok else 'FAIL'}  {q['id']:8} {q['family']:8} {results[-1]['seconds']:5}s  tools={tools}  "
              + "  ".join(f"{k}:{'ok' if v[0] else v[1]}" for k, v in checks.items()))

    total = len(results)
    print(f"\n{passed}/{total} passed ({100 * passed / max(total, 1):.0f}%)")
    # one row per question in GROCERY_APP.AGENT_RUN_LOG (SOURCE = eval) so the
    # ops layer's eval_score sensor can trend the score without this file
    try:
        cur = conn.cursor()
        cur.executemany(
            "INSERT INTO GROCERYDBTPROJECT.GROCERY_APP.AGENT_RUN_LOG (SHOPPER_ID, SOURCE, QUESTION, TOOLS, LATENCY_MS, PASSED) "
            "SELECT CURRENT_USER(), 'eval', %s, %s, %s, %s",
            [(r["id"] + ": " + next(q["question"] for q in questions if q["id"] == r["id"]), json.dumps(r["tools"]), int(r["seconds"] * 1000), bool(r["pass"])) for r in results],
        )
        print(f"logged {len(results)} rows to GROCERY_APP.AGENT_RUN_LOG (source=eval)")
    except Exception as e:  # logging must never fail the eval
        print(f"could not log to AGENT_RUN_LOG: {e}")
    out = HERE / f"results_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
    out.write_text(json.dumps({"schema": schema, "passed": passed, "total": total, "results": results}, indent=1))
    print(f"written {out}")
    return 0 if passed >= 0.9 * total else 1


if __name__ == "__main__":
    sys.exit(main())
