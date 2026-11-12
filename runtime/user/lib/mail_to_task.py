#!/usr/bin/env python3
"""
mail_to_task.py

Reads an email from stdin and creates a Taskwarrior task
tagged +todo unless a task for this Message-ID already exists
(based on mh_<hashprefix> lookup token).

Normalization strategy:
- Store ONE canonical Message-ID reference as an annotation:   mid:<raw-message-id>
- Store ONE short, stable lookup token in the description:     mh_<hashprefix>

Task description (short, human-first):
  [ma_<acct>] mh_<hash> <subject>

Task annotations:
  mid:<raw-message-id>
  from:<decoded-from>

Optionally opens $VISUAL / $EDITOR (fallback: vim) to edit the description.
"""

from __future__ import annotations

import argparse
import base64
import email
import hashlib
import os
import re
import subprocess
import sys
import tempfile
from email.header import decode_header, make_header
from email.message import Message

DEBUG = False


def debug_log(message: str) -> None:
    if DEBUG:
        print(message, file=sys.stderr)


def collapse_whitespace(text: str | None) -> str:
    return re.sub(r"\s+", " ", (text or "")).strip()


def decode_email_header(header_value: str | None) -> str:
    if not header_value:
        return ""
    try:
        return str(make_header(decode_header(header_value)))
    except Exception:
        return header_value


def truncate(text: str, max_len: int) -> str:
    t = collapse_whitespace(text)
    if len(t) <= max_len:
        return t
    return t[: max_len - 1] + "…"


def run_command(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    debug_log(f"Running: {arguments}")
    return subprocess.run(arguments, text=True, capture_output=True)


def exit_with_message(message: str, exit_code: int = 1) -> None:
    print(message, file=sys.stderr)
    sys.exit(exit_code)


def extract_message_id(email_message: Message) -> str:
    raw = collapse_whitespace(email_message.get("Message-ID"))
    if not raw:
        return ""
    return raw.strip("<>").strip()


def build_hash_lookup_token(message_id: str, length: int = 10) -> str:
    digest = hashlib.sha256(message_id.encode("utf-8")).digest()
    b32 = base64.b32encode(digest).decode("ascii").rstrip("=").lower()
    return f"mh_{b32[:length]}"


def build_account_token(account: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9]+", "_", account or "").strip("_").lower()
    return f"ma_{safe}" if safe else ""


def task_base_args() -> list[str]:
    return ["task", "rc.verbose:nothing", "rc.color:off"]


def task_exists_by_lookup_token(lookup_token: str) -> bool:
    result = run_command(task_base_args() + ["status:pending", lookup_token, "ids"])

    if result.returncode not in (0, 1):
        exit_with_message(
            f"Taskwarrior query failed: {result.stderr.strip() or result.stdout.strip()}"
        )

    return bool(result.stdout.strip().split())


def create_task(description_text: str) -> None:
    result = run_command(task_base_args() + ["add", "project:email", description_text])
    if result.returncode != 0:
        exit_with_message(
            f"Taskwarrior add failed: {result.stderr.strip() or result.stdout.strip()}"
        )


def find_task_id(lookup_token: str) -> str:
    result = run_command(task_base_args() + ["status:pending", lookup_token, "ids"])
    if result.returncode not in (0, 1):
        exit_with_message(
            f"Taskwarrior query failed: {result.stderr.strip() or result.stdout.strip()}"
        )

    ids = result.stdout.strip().split()
    return ids[0] if ids else ""


def annotate_task(task_id: str, note: str) -> None:
    result = run_command(task_base_args() + [task_id, "annotate", note])
    if result.returncode != 0:
        exit_with_message(
            f"Taskwarrior annotate failed: {result.stderr.strip() or result.stdout.strip()}"
        )


def create_task_and_annotate(
    description: str,
    lookup_token: str,
    annotations: list[str],
) -> None:
    create_task(description)

    task_id = find_task_id(lookup_token)
    if not task_id:
        exit_with_message("Task was created but could not be found for annotation.")

    for note in annotations:
        if note:
            annotate_task(task_id, note)


def edit_in_editor(initial_text: str) -> str:
    editor = os.environ.get("VISUAL") or os.environ.get("EDITOR") or "vim"

    fd, path = tempfile.mkstemp(prefix="mail_to_task_", suffix=".txt")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(initial_text.rstrip() + "\n")

        subprocess.run([editor, path], check=True)

        with open(path, "r", encoding="utf-8", errors="replace") as f:
            edited = f.read()

        return collapse_whitespace(edited)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("account_positional", nargs="?")
    p.add_argument("-a", "--account")
    p.add_argument("--no-edit", action="store_true")
    p.add_argument("--hash-len", type=int, default=10)
    p.add_argument("--subject-len", type=int, default=55)
    return p.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    account = args.account or args.account_positional or ""
    account_token = build_account_token(account)

    email_message = email.message_from_binary_file(sys.stdin.buffer)

    subject = collapse_whitespace(
        decode_email_header(email_message.get("Subject")) or "(no subject)"
    )
    sender = collapse_whitespace(
        decode_email_header(email_message.get("From")) or "(no sender)"
    )

    message_id = extract_message_id(email_message)
    if not message_id:
        exit_with_message("No Message-ID header found; no task created.", 0)

    lookup_token = build_hash_lookup_token(message_id, length=max(4, args.hash_len))

    if task_exists_by_lookup_token(lookup_token):
        print(
            "Task already exists for this email; no new task created.",
            file=sys.stderr,
        )
        return 0

    subject_short = truncate(subject, max(10, args.subject_len))

    if account_token:
        description = f"{account_token} {lookup_token} {subject_short}"
    else:
        description = f"{lookup_token} {subject_short}"

    annotations = [
        f"mid:{message_id}",
        f"from:{sender}",
    ]

    if not args.no_edit:
        description = edit_in_editor(description)
        if not description:
            print(
                "Empty description after editor; no task created.",
                file=sys.stderr,
            )
            return 0

    create_task_and_annotate(description, lookup_token, annotations)

    print("Created Taskwarrior task +todo.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
