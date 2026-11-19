#!/usr/bin/env python3
"""LanguageTool checker for minx

Masking, ignore list, language mapping, server call, match handling and mail
draft trimming all live here. Front-ends only call it:

  pre-commit   lt_check.py FILE [FILE ...]
  Vim / ALE    lt_check.py --format gcc --spelllang en_us FILE
               ('file:line:col: message', understood by errorformat and ALE)
  stdin        lt_check.py --format gcc --first-line 10 --filename F -

Environment (all optional):
  LANGUAGETOOL_URL        server base URL      (default http://localhost:8085)
  LANGUAGETOOL_LANGUAGE   language             (default en-US)
  LT_IGNORE_FILE          ignore word list     (default: nearest
                          .languagetool-ignore above the file, then above cwd)

Exit status: 0 = ok, 1 = issues found (--format text only), 2 = error.
"""

from __future__ import annotations

import argparse
import bisect
import json
import os
import re
import sys
from dataclasses import dataclass, field
from functools import lru_cache
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

DEFAULT_URL = "http://localhost:8085"
DEFAULT_LANGUAGE = "en-US"
IGNORE_NAME = ".languagetool-ignore"
CONTEXT_RADIUS = 65
TIMEOUT = 30
MAX_PROBLEM_CHARS = 60

# Vim 'spelllang' -> LanguageTool language code (first entry only).
DEFAULT_LANGUAGE_MAP = {
    "en": "en-US",
    "de": "de-DE",
    "es": "es",
}


class LTError(Exception):
    """Any failure that should end the run with a readable message."""


# ---------------------------------------------------------------------------
# Configuration helpers
# ---------------------------------------------------------------------------


def normalize_url(base):
    endpoint = base.rstrip("/")
    if not endpoint.endswith("/v2/check"):
        endpoint += "/v2/check"
    return endpoint


def parse_language_map(spec):
    """'de=de-CH,en=en-GB' -> {'de': 'de-CH', 'en': 'en-GB'}"""
    result = {}
    for item in filter(None, (part.strip() for part in spec.split(","))):
        key, sep, value = item.partition("=")
        if sep and key.strip() and value.strip():
            result[key.strip().lower()] = value.strip()
    return result


def spelllang_to_lt(spelllang, overrides=None):
    """Map a Vim 'spelllang' value to a LanguageTool code (None if empty)."""
    first = spelllang.split(",")[0].strip().lower()
    first = re.sub(r"@.*$", "", first)
    if not first:
        return None

    mapping = {**DEFAULT_LANGUAGE_MAP, **(overrides or {})}
    if first in mapping:
        return mapping[first]

    parts = re.split(r"[_-]", first)
    if len(parts) == 2:  # en_gb -> en-GB, de_at -> de-AT
        return f"{parts[0]}-{parts[1].upper()}"
    return first


def resolve_language(args):
    if args.language:
        return args.language
    if args.spelllang:
        language = spelllang_to_lt(
            args.spelllang, parse_language_map(args.language_map)
        )
        if language:
            return language
    return os.environ.get("LANGUAGETOOL_LANGUAGE") or DEFAULT_LANGUAGE


def find_ignore_file(explicit, start_dirs):
    """Explicit path / $LT_IGNORE_FILE, else nearest file above start_dirs."""
    path = explicit or os.environ.get("LT_IGNORE_FILE")
    if path:
        return path

    for start in start_dirs:
        directory = os.path.abspath(start)
        while True:
            candidate = os.path.join(directory, IGNORE_NAME)
            if os.path.isfile(candidate):
                return candidate
            parent = os.path.dirname(directory)
            if parent == directory:
                break
            directory = parent
    return None


@lru_cache(maxsize=None)
def load_ignored(path):
    """Case-folded set of ignored words (one per line, '#' comments)."""
    if not path or not os.path.isfile(path):
        return frozenset()

    with open(path, encoding="utf-8") as file:
        return frozenset(
            line.strip().casefold()
            for line in file
            if line.strip() and not line.lstrip().startswith("#")
        )


# ---------------------------------------------------------------------------
# Input and masking
# ---------------------------------------------------------------------------


def read_input(path):
    """Read a file ('-' = stdin) as UTF-8 with universal newlines."""
    try:
        if path == "-":
            raw = sys.stdin.buffer.read()
        else:
            with open(path, "rb") as file:
                raw = file.read()
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise LTError(f"{path}: not valid UTF-8 ({error})")
    except OSError as error:
        raise LTError(f"{path}: {error.strerror or error}")

    return text.replace("\r\n", "\n").replace("\r", "\n")


def mask_markdown(text):
    """Mask fenced code, Markdown table padding and inline code.

    Every character is replaced by one '*' and line breaks are never touched,
    so offsets and line numbers stay valid.
    """

    # Split on "\n" only (str.splitlines() also splits on \x0b, \u2028, ...).
    lines = re.findall(r"[^\n]*\n|[^\n]+", text)
    result = []

    fence_char = None
    fence_length = 0

    for line in lines:
        stripped = line.rstrip("\r\n")

        if fence_char:
            result.append(re.sub(r"[^\r\n]", "*", line))

            closing = re.match(r"^ {0,3}(`+|~+)[ \t]*$", stripped)
            if (
                closing
                and closing.group(1)[0] == fence_char
                and len(closing.group(1)) >= fence_length
            ):
                fence_char = None
                fence_length = 0
            continue

        opening = re.match(r"^ {0,3}(`{3,}|~{3,})", stripped)
        if opening:
            marker = opening.group(1)
            fence_char = marker[0]
            fence_length = len(marker)
            result.append(re.sub(r"[^\r\n]", "*", line))
            continue

        # Markdown table: keep one whitespace character of every padding run.
        if re.match(r"^\s*\|.*\|\s*$", stripped):
            line = re.sub(
                r"[ \t]{2,}",
                lambda m: m.group(0)[0] + "*" * (len(m.group(0)) - 1),
                line,
            )

        result.append(line)

    text = "".join(result)

    # Inline code spans, including multi-backtick delimiters.
    def mask_inline(match):
        if match.group(1) != match.group(3):
            return match.group(0)
        return match.group(1) + re.sub(r"[^\r\n]", "*", match.group(2)) + match.group(3)

    return re.sub(r"(`+)(.+?)(`+)", mask_inline, text, flags=re.DOTALL)


# ---------------------------------------------------------------------------
# Server and offsets
# ---------------------------------------------------------------------------


def query_server(url, language, text, timeout=TIMEOUT):
    data = urlencode({"language": language, "text": text}).encode("utf-8")
    request = Request(
        url,
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )

    try:
        with urlopen(request, timeout=timeout) as response:
            result = json.loads(response.read().decode("utf-8"))
    except HTTPError as error:  # must come before OSError (its base class)
        detail = error.read().decode("utf-8", "replace").strip()[:300]
        raise LTError(f"server returned HTTP {error.code}: {detail}")
    except (OSError, ValueError) as error:
        raise LTError(f"server call failed: {error}")

    if not isinstance(result, dict) or not isinstance(result.get("matches"), list):
        raise LTError("invalid LanguageTool response")

    return result["matches"]


class Utf16Index:
    """Convert LanguageTool UTF-16 offsets to Python string indices."""

    def __init__(self, text):
        self._length = len(text)
        self._table = None

        if any(ord(char) > 0xFFFF for char in text):
            table = []
            for index, char in enumerate(text):
                table.append(index)
                if ord(char) > 0xFFFF:
                    table.append(index)
            table.append(len(text))
            self._table = table

    def to_index(self, offset):
        if self._table is None:
            return max(0, min(offset, self._length))
        return self._table[max(0, min(offset, len(self._table) - 1))]


def load_line_starts(text):
    """Python character index at which each line starts."""
    return [0] + [match.end() for match in re.finditer("\n", text)]


# ---------------------------------------------------------------------------
# Checking
# ---------------------------------------------------------------------------


@dataclass
class Issue:
    line: int  # 1-based, first_line already applied
    column: int  # 1-based, UTF-8 bytes (what Vim expects)
    rule: str
    message: str
    problem: str
    source_line: str
    suggestions: list = field(default_factory=list)
    context: str = ""


def check_text(
    text,
    language,
    url,
    ignored=frozenset(),
    mask=True,
    first_line=1,
    timeout=TIMEOUT,
):
    original = text
    masked = mask_markdown(original) if mask else original

    matches = query_server(url, language, masked, timeout)

    utf16 = Utf16Index(masked)
    line_starts = load_line_starts(original)
    issues = []

    for match in matches:
        if not isinstance(match, dict):
            continue

        offset = match.get("offset")
        length = match.get("length")
        message = match.get("message")

        if (
            not isinstance(offset, int)
            or isinstance(offset, bool)
            or not isinstance(length, int)
            or isinstance(length, bool)
            or not isinstance(message, str)
        ):
            continue

        index = utf16.to_index(offset)
        end = utf16.to_index(offset + length)

        rule_obj = match.get("rule")
        rule = rule_obj.get("id", "") if isinstance(rule_obj, dict) else ""
        if not isinstance(rule, str):
            rule = ""

        # Ignore configured terms for any LanguageTool rule.
        problem = original[index:end]
        if problem.casefold() in ignored:
            continue

        line_idx = bisect.bisect_right(line_starts, index) - 1
        line_start = line_starts[line_idx]
        if line_idx + 1 < len(line_starts):
            line_end = line_starts[line_idx + 1] - 1
        else:
            line_end = len(original)

        replacements = match.get("replacements")
        if not isinstance(replacements, list):
            replacements = []
        suggestions = [
            item["value"]
            for item in replacements[:3]
            if isinstance(item, dict)
            and isinstance(item.get("value"), str)
            and item["value"]
        ]

        context = original[
            max(0, index - CONTEXT_RADIUS) : min(len(original), end + CONTEXT_RADIUS)
        ]

        issues.append(
            Issue(
                line=first_line + line_idx,
                column=len(original[line_start:index].encode("utf-8")) + 1,
                rule=rule,
                message=message,
                problem=problem,
                source_line=original[line_start:line_end].rstrip("\r"),
                suggestions=suggestions,
                context=re.sub(r"\s+", " ", context).strip(),
            )
        )

    return issues


# ---------------------------------------------------------------------------
# Output formats
# ---------------------------------------------------------------------------


def format_text(issue, filename):
    """Human readable (pre-commit)."""
    suggestions = ", ".join(issue.suggestions) if issue.suggestions else "none"
    return "\n".join(
        [
            f"{filename}:{issue.line}:{issue.column}: {issue.message} [{issue.rule}]",
            f"  Problem: {issue.problem!r}",
            f"  Source: {issue.source_line}",
            f"  Suggestions: {suggestions}",
            f"  Context: ...{issue.context}...",
            "",
        ]
    )


def format_gcc(issue, filename):
    """One line per issue: file:line:col: message [rule] | problem | suggestions."""
    text = " ".join(issue.message.split())
    if issue.rule:
        text += f" [{issue.rule}]"

    problem = " ".join(issue.problem.split())[:MAX_PROBLEM_CHARS]
    if problem:
        text += f" | problem: '{problem}'"

    if issue.suggestions:
        text += " | suggestions: " + ", ".join(issue.suggestions)

    return f"{filename}:{issue.line}:{issue.column}: {text}"


# ---------------------------------------------------------------------------
# Mail drafts
# ---------------------------------------------------------------------------

MAIL_HEADER = re.compile(
    r"^(From|To|Cc|Bcc|Subject|Reply-To|Date|In-Reply-To|References|Message-ID|X-[^:]+):",
    re.IGNORECASE,
)
MAIL_SALUTATIONS = [
    "best regards", "kind regards", "regards", "thanks", "thank you",
    "sincerely", "cheers",
    "mit freundlichen grüßen", "beste grüße", "viele grüße",
    "liebe grüße", "freundliche grüße",
]  # fmt: skip
MAIL_HISTORY = [
    r"^On .+wrote:\s*$",
    r"^Am .+schrieb .+:\s*$",
    r"^From:\s+",
    r"^Sent:\s+",
    r"^To:\s+",
    r"^Subject:\s+",
    r"^---\s*Original Message\s*---\s*$",
    r"^---\s*Forwarded message\s*---\s*$",
    r"^--\s*$",
    r"^\s*>",
]


def mail_body_range(lines, salutations=(), history=()):
    """(start, end) indices of the part of a mail draft worth checking.

    Skips a header block at the top and stops at the first sign-off line or
    quoted-history marker.
    """
    salutations = {s.strip().lower() for s in (*MAIL_SALUTATIONS, *salutations)}
    patterns = [re.compile(p) for p in (*MAIL_HISTORY, *history)]

    start = 0
    if lines and MAIL_HEADER.match(lines[0]):
        start = next((i + 1 for i, l in enumerate(lines) if not l.strip()), len(lines))

    for index in range(start, len(lines)):
        line = lines[index]
        normalized = re.sub(r"[,.!:;\s]+$", "", line.strip()).lower()
        if normalized in salutations or any(p.search(line) for p in patterns):
            return start, index
    return start, len(lines)


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------


def build_parser():
    parser = argparse.ArgumentParser(
        description="Check files with a LanguageTool server.",
        epilog="Use '-' as FILE to read stdin.",
    )
    parser.add_argument("files", nargs="+", metavar="FILE")
    parser.add_argument(
        "--format",
        choices=["text", "gcc"],
        default="text",
        help="text: multi-line (pre-commit), gcc: file:line:col: message",
    )
    parser.add_argument("--language", help="LanguageTool language code")
    parser.add_argument(
        "--spelllang", help="Vim 'spelllang' value (mapped to a language)"
    )
    parser.add_argument(
        "--language-map",
        default="",
        metavar="K=V,...",
        help="extra/overriding spelllang mappings, e.g. de=de-CH,en=en-GB",
    )
    parser.add_argument("--url", help="server URL (default $LANGUAGETOOL_URL)")
    parser.add_argument("--ignore-file", help="ignore word list")
    parser.add_argument("--no-mask", action="store_true", help="do not mask code")
    parser.add_argument(
        "--first-line",
        type=int,
        default=1,
        metavar="N",
        help="line number of the first input line (for buffer ranges)",
    )
    parser.add_argument(
        "--filename",
        help="real name of the input (display and ignore-file lookup), "
        "for stdin or temporary copies",
    )
    parser.add_argument(
        "--mail",
        action="store_true",
        help="mail draft: skip headers, stop at sign-off / quoted history",
    )
    parser.add_argument(
        "--mail-salutation",
        action="append",
        default=[],
        metavar="TEXT",
        help="extra sign-off line (repeatable)",
    )
    parser.add_argument(
        "--mail-history",
        action="append",
        default=[],
        metavar="REGEX",
        help="extra quoted-history regex, Python syntax (repeatable)",
    )
    return parser


def main(argv=None):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass

    args = build_parser().parse_args(argv)

    try:
        language = resolve_language(args)
        url = normalize_url(
            args.url or os.environ.get("LANGUAGETOOL_URL") or DEFAULT_URL
        )

        found = 0

        for path in args.files:
            display = args.filename or ("<stdin>" if path == "-" else path)

            start_dirs = [os.getcwd()]
            if display != "<stdin>":
                start_dirs.insert(0, os.path.dirname(os.path.abspath(display)))
            ignored = load_ignored(find_ignore_file(args.ignore_file, start_dirs))

            text = read_input(path)
            first_line = args.first_line

            if args.mail:
                lines = text.split("\n")
                start, end = mail_body_range(
                    lines, args.mail_salutation, args.mail_history
                )
                text = "\n".join(lines[start:end]) + "\n"
                first_line += start
                if not text.strip():
                    continue

            issues = check_text(
                text,
                language,
                url,
                ignored=ignored,
                mask=not args.no_mask,
                first_line=first_line,
            )

            for issue in issues:
                found += 1
                if args.format == "text":
                    print(format_text(issue, display))
                else:
                    print(format_gcc(issue, display))

    except LTError as error:
        print(f"LanguageTool error: {error}", file=sys.stderr)
        return 2

    return 1 if (found and args.format == "text") else 0


if __name__ == "__main__":
    sys.exit(main())
