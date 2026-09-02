#!/usr/bin/env python3
import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path


def fail(message: str, details=None, exit_code: int = 1):
    payload = {"error": message}
    if details is not None:
        payload["details"] = details
    print(json.dumps(payload, indent=2), file=sys.stderr)
    raise SystemExit(exit_code)


def api_request(method: str, path: str, payload=None, timeout: int = 60):
    base = os.environ["TACTICAL_API_URL"].rstrip("/")
    key = os.environ["TACTICAL_API_KEY"]
    headers = {
        "Accept": "application/json",
        "X-API-KEY": key,
    }
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{base}{path}",
        data=data,
        headers=headers,
        method=method,
    )
    with urllib.request.urlopen(
        req,
        context=ssl.create_default_context(),
        timeout=timeout,
    ) as resp:
        body = resp.read().decode("utf-8", "replace")
        return resp.status, body


def get_json(path: str):
    _, body = api_request("GET", path)
    return json.loads(body)


def ensure_agent(hostname: str):
    agents = get_json("/agents/")
    matches = [a for a in agents if a.get("hostname") == hostname]
    if len(matches) != 1:
        fail(
            "Agent safety check failed",
            f"Expected exactly one agent matching {hostname!r}, found {len(matches)}",
        )
    return matches[0]


def ensure_script(
    name: str,
    script_path: Path,
    description: str,
    timeout: int,
    category: str,
):
    scripts = get_json("/scripts/")
    existing = [s for s in scripts if s.get("name") == name]
    body = script_path.read_text()
    payload = {
        "name": name,
        "description": description,
        "shell": "shell",
        "category": category,
        "script_body": body,
        "default_timeout": timeout,
        "run_as_user": False,
        "args": [],
        "env_vars": [],
        "favorite": False,
        "supported_platforms": ["linux"],
    }

    if not existing:
        status, response = api_request("POST", "/scripts/", payload)
        return {"action": "created", "status": status, "script": json.loads(response)}

    script_id = existing[0]["id"]
    status, response = api_request("PUT", f"/scripts/{script_id}/", payload)
    return {"action": "updated", "status": status, "script": json.loads(response)}


def get_script(name: str):
    scripts = get_json("/scripts/")
    matches = [s for s in scripts if s.get("name") == name]
    if len(matches) != 1:
        fail(
            "Script lookup failed",
            f"Expected exactly one script named {name!r}, found {len(matches)}",
        )
    return matches[0]


def run_script(agent_id: str, script_id: int, timeout: int):
    payload = {
        "output": "wait",
        "emails": [],
        "emailMode": "default",
        "custom_field": None,
        "save_all_output": False,
        "script": script_id,
        "args": [],
        "env_vars": [],
        "run_as_user": False,
        "timeout": timeout,
    }
    status, response = api_request(
        "POST",
        f"/agents/{agent_id}/runscript/",
        payload,
        timeout=max(timeout + 60, 120),
    )
    return {"status": status, "response": json.loads(response)}


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("agent")
    script_id_parser = sub.add_parser("script-id")
    script_id_parser.add_argument("name")

    script_parser = sub.add_parser("script")
    script_parser.add_argument("name")
    script_parser.add_argument("path")
    script_parser.add_argument(
        "--description",
        default="Managed Tactical automation script",
    )
    script_parser.add_argument(
        "--timeout",
        type=int,
        default=90,
    )
    script_parser.add_argument(
        "--category",
        default="DDELANEY (Linux):Automations",
    )

    run_parser = sub.add_parser("run")
    run_parser.add_argument("agent_id")
    run_parser.add_argument("script_id", type=int)
    run_parser.add_argument(
        "--timeout",
        type=int,
        default=90,
    )

    args = parser.parse_args()
    hostname = "cets-mon-poc-01"

    try:
        if args.cmd == "agent":
            print(json.dumps(ensure_agent(hostname), indent=2))
        elif args.cmd == "script-id":
            print(json.dumps(get_script(args.name), indent=2))
        elif args.cmd == "script":
            print(
                json.dumps(
                    ensure_script(
                        args.name,
                        Path(args.path),
                        args.description,
                        args.timeout,
                        args.category,
                    ),
                    indent=2,
                )
            )
        elif args.cmd == "run":
            agent = ensure_agent(hostname)
            if agent["agent_id"] != args.agent_id:
                fail("Agent ID does not match exact hostname lookup")
            print(
                json.dumps(
                    run_script(args.agent_id, args.script_id, args.timeout),
                    indent=2,
                )
            )
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        fail(
            "Tactical API request failed",
            {
                "http_error": exc.code,
                "reason": str(exc.reason),
                "body": body,
            },
        )
    except urllib.error.URLError as exc:
        fail("Unable to reach Tactical API", str(exc.reason))
    except FileNotFoundError as exc:
        fail("Script file not found", str(exc))
    except KeyError as exc:
        fail("Required environment variable is missing", str(exc))
    except json.JSONDecodeError as exc:
        fail("Received invalid JSON from Tactical API", str(exc))
    except Exception as exc:
        fail("Unexpected automation error", str(exc))


if __name__ == "__main__":
    main()
