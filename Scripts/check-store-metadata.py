#!/usr/bin/env python3
"""Check the App Store texts under store/: field limits, formatting, URLs and the public-text rules.

Python 3 standard library only. Prints PASS or FAIL for each file and exits 0 only if every check passes.
Nothing here contacts Apple or uploads anything.
"""
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STORE = ROOT / "store"

LIMITS = {
    "metadata/en-US/name.txt": 30,
    "metadata/en-US/subtitle.txt": 30,
    "metadata/en-US/promotional_text.txt": 170,
    "metadata/en-US/description.txt": 4000,
    "metadata/en-US/keywords.txt": 100,
    "metadata/en-US/release_notes.txt": 4000,
}
REQUIRED = list(LIMITS) + [
    "README.md",
    "metadata/copyright.txt",
    "metadata/categories.txt",
    "metadata/en-US/support_url.txt",
    "metadata/en-US/marketing_url.txt",
    "metadata/en-US/privacy_url.txt",
]
URL_FILES = {
    "metadata/en-US/support_url.txt": "https://meshlive.github.io/support/",
    "metadata/en-US/marketing_url.txt": "https://meshlive.github.io/",
    "metadata/en-US/privacy_url.txt": "https://meshlive.github.io/privacy/",
}
TERMS_URL = "https://meshlive.github.io/terms/"
APPROVED_URLS = list(URL_FILES.values()) + [TERMS_URL]

FORBIDDEN = [
    "beta", "testflight", "github", "go live", "wi-fi direct", "chat", "chats", "mac app",
    "disaster", "rescue", "lifesaving", "life-saving", "sos", "survival", "protest",
    "censorship", "untraceable", "unhackable", "military-grade", "anonymous", "100%",
]
# Words that must never reach the listing (a workstation name, a team ID): comma-separated in MESHLIVE_PRIVATE_WORDS,
# kept out of the repository.
PRIVATE_WORDS = [w.strip() for w in os.environ.get("MESHLIVE_PRIVATE_WORDS", "").split(",") if w.strip()]
PRIVATE_PATTERNS = [r"/Users/", r"D:\\", r"192\.168\.", r"2026[0-9]{4}"]
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")

problems: dict[str, list[str]] = {}


def fail(rel: str, reason: str) -> None:
    problems.setdefault(rel, []).append(reason)


def load(rel: str) -> "str | None":
    path = STORE / rel
    if not path.is_file():
        fail(rel, "missing")
        return None
    data = path.read_bytes()
    text = data.decode("utf-8", errors="replace")
    if not data:
        fail(rel, "empty")
    if b"\r" in data:
        fail(rel, "CR line ending (LF only)")
    if b"\t" in data:
        fail(rel, "tab character")
    if not data.endswith(b"\n"):
        fail(rel, "no trailing newline")
    elif data.endswith(b"\n\n"):
        fail(rel, "more than one trailing newline")
    for number, line in enumerate(text.split("\n"), 1):
        if line.endswith(" "):
            fail(rel, f"trailing space on line {number}")
    return text[:-1] if text.endswith("\n") else text


def whole_word(word: str, text: str) -> bool:
    return re.search(r"(?<![a-z0-9])" + re.escape(word) + r"(?![a-z0-9])", text, re.IGNORECASE) is not None


def check_keywords(rel: str, content: str) -> None:
    if re.search(r",\s", content):
        fail(rel, "space after a comma")
    terms = content.split(",")
    if any(not term for term in terms):
        fail(rel, "empty keyword")
    name = (STORE / "metadata/en-US/name.txt").read_text().strip()
    subtitle = (STORE / "metadata/en-US/subtitle.txt").read_text().strip()
    used = set(re.findall(r"[a-z0-9]+", name.lower())) | set(re.findall(r"[a-z0-9]+", subtitle.lower()))
    seen: set[str] = set()
    for term in terms:
        if term != term.strip():
            fail(rel, "space around a keyword")
        if "meshlive" in term.lower():
            fail(rel, "app name in keywords")
        for word in re.findall(r"[a-z0-9]+", term.lower()):
            if word in seen:
                fail(rel, f"duplicate word '{word}'")
            if word in used:
                fail(rel, f"word '{word}' is already in the name or subtitle")
            seen.add(word)


def main() -> int:
    contents: dict[str, str] = {}
    for rel in REQUIRED:
        content = load(rel)
        if content is not None:
            contents[rel] = content
    for rel, limit in LIMITS.items():
        content = contents.get(rel)
        if content is not None and len(content) > limit:
            fail(rel, f"{len(content)} characters (limit {limit})")

    if contents.get("metadata/en-US/keywords.txt") is not None:
        check_keywords("metadata/en-US/keywords.txt", contents["metadata/en-US/keywords.txt"])

    for rel, expected in URL_FILES.items():
        content = contents.get(rel)
        if content is None:
            continue
        value = content.strip()
        if value != expected:
            fail(rel, f"'{value}' does not match '{expected}'")
        if not value.startswith("https://"):
            fail(rel, "URL is not https")
        if "?" in value:
            fail(rel, "URL has a query string")

    description = contents.get("metadata/en-US/description.txt", "")
    for url in (TERMS_URL, URL_FILES["metadata/en-US/privacy_url.txt"]):
        if url not in description:
            fail("metadata/en-US/description.txt", f"missing link {url}")

    promotional = contents.get("metadata/en-US/promotional_text.txt", "")
    android_count = len(re.findall(r"\bAndroid\b", promotional + " " + description))
    if android_count > 1:
        fail("metadata/en-US/description.txt", f"'Android' appears {android_count} times in description and promotional text (at most 1)")

    files = sorted(path for path in STORE.rglob("*") if path.is_file() and path.suffix.lower() in (".txt", ".md"))
    for path in files:
        rel = path.relative_to(STORE).as_posix()
        content = contents.get(rel)
        if content is None:
            content = load(rel)
            if content is None:
                continue
            contents[rel] = content
        lowered = content.lower()

        # URLs: https, no query string.
        for url in re.findall(r"https?://[^\s<>\"']+", content):
            url = url.rstrip(".,;:)")
            if not url.startswith("https://"):
                fail(rel, f"URL is not https: {url}")
            if "?" in url:
                fail(rel, f"URL has a query string: {url}")

        # Approved URLs contain the project name; remove them before the word scan.
        scan = content
        for url in APPROVED_URLS:
            scan = scan.replace(url, " ")
        scan = re.sub(r"does not make you anonymous", " ", scan, flags=re.IGNORECASE)
        lowered_scan = scan.lower()
        for word in FORBIDDEN:
            if word == "github" and rel.startswith("web/"):
                continue
            if word == "anonymous":
                if re.search(r"(?<![a-z0-9])anonymous(?![a-z0-9])", scan, re.IGNORECASE):
                    fail(rel, "forbidden word 'anonymous' outside 'does not make you anonymous'")
                continue
            if whole_word(word, scan):
                fail(rel, f"forbidden word '{word}'")

        # Emergency/emergencies only in a sentence that says not for/not replace or tells people to contact services.
        for sentence in re.split(r"(?<=[.!?])\s+|\n+", content):
            low = sentence.lower()
            if "emergenc" not in low:
                continue
            allowed = ("not replace" in low or "not for" in low
                       or ("contact" in low and "emergency services" in low))
            if not allowed:
                fail(rel, "emergency/emergencies outside the approved sentences")

        for word in PRIVATE_WORDS:
            if word.lower() in lowered:
                fail(rel, f"private detail '{word}'")
        for pattern in PRIVATE_PATTERNS:
            if re.search(pattern, content):
                fail(rel, f"private detail matching {pattern}")
        if rel != "metadata/review_notes.txt":
            for email in EMAIL_RE.findall(content):
                if email.lower() != "meshlive.dev@gmail.com":
                    fail(rel, f"email address '{email}' is not the project address")

    for rel in sorted(set(REQUIRED) | set(contents) | set(files_relative(STORE, files))):
        if rel in problems:
            for reason in problems[rel]:
                print(f"FAIL {rel}: {reason}")
        else:
            print(f"PASS {rel}")

    if problems:
        print(f"{sum(len(v) for v in problems.values())} check(s) failed")
        return 1
    return 0


def files_relative(root: Path, files: list[Path]) -> list[str]:
    return [path.relative_to(root).as_posix() for path in files]


if __name__ == "__main__":
    sys.exit(main())
