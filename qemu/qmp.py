#!/usr/bin/env python3

"""Send one command to a QEMU Machine Protocol Unix socket."""

import argparse
import json
import socket
import sys
import time


def read_reply(stream, request_id, deadline):
    while time.monotonic() < deadline:
        line = stream.readline()
        if not line:
            raise RuntimeError("QMP connection closed before a reply arrived")
        message = json.loads(line)
        if message.get("id") == request_id:
            return message
    raise TimeoutError("timed out waiting for a QMP reply")


def execute(stream, command, arguments, request_id, deadline):
    request = {"execute": command, "id": request_id}
    if arguments:
        request["arguments"] = arguments
    stream.write((json.dumps(request) + "\r\n").encode())
    return read_reply(stream, request_id, deadline)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("socket")
    parser.add_argument("command")
    parser.add_argument("arguments", nargs="?", default="{}")
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()

    arguments = json.loads(args.arguments)
    if not isinstance(arguments, dict):
        parser.error("arguments must be a JSON object")

    deadline = time.monotonic() + args.timeout
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(args.timeout)
    connection.connect(args.socket)
    stream = connection.makefile("rwb", buffering=0)

    greeting = json.loads(stream.readline())
    if "QMP" not in greeting:
        raise RuntimeError(f"invalid QMP greeting: {greeting!r}")

    capabilities = execute(stream, "qmp_capabilities", {}, "capabilities", deadline)
    if "error" in capabilities:
        print(json.dumps(capabilities), file=sys.stderr)
        return 1

    reply = execute(stream, args.command, arguments, "command", deadline)
    print(json.dumps(reply, separators=(",", ":")))
    return 1 if "error" in reply else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, TimeoutError, json.JSONDecodeError) as error:
        print(f"qmp.py: {error}", file=sys.stderr)
        raise SystemExit(1)
