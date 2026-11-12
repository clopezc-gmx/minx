#!/usr/bin/env python3

"""
mail_open_html.py

Open the HTML part of an email from neomutt.

Extract the first text/html part from a raw message (file or stdin),
write it to a temporary .html file, and print the file path.
"""

import sys
import email
import tempfile
import webbrowser
from email import policy


def extract_html(msg):
    """
    Recursively find the first HTML part in the email.
    Works for both attachments and inline HTML.
    """
    if msg.is_multipart():
        for part in msg.iter_parts():
            html = extract_html(part)
            if html:
                return html
    else:
        # Check if this part is text/html
        if msg.get_content_type() == "text/html":
            charset = msg.get_content_charset() or "utf-8"
            return msg.get_payload(decode=True).decode(charset, errors="replace")
    return None


def main():
    # Read email from file (passed as argument) or stdin
    if len(sys.argv) > 1:
        with open(sys.argv[1], "rb") as f:
            msg = email.message_from_binary_file(f, policy=policy.default)
    else:
        msg = email.message_from_binary_file(sys.stdin.buffer, policy=policy.default)

    html_content = extract_html(msg)

    if not html_content:
        print("No HTML content found in this email.", file=sys.stderr)
        sys.exit(1)

    # Write HTML to a temporary file and open in default browser
    with tempfile.NamedTemporaryFile(
        "w", suffix=".html", delete=False, encoding="utf-8"
    ) as tmpfile:
        tmpfile.write(html_content)
        tmpname = tmpfile.name

    # Print the file path (so Bash can open it)
    print(tmpname)


if __name__ == "__main__":
    main()
