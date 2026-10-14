"""Every relative link in README.md and docs/*.md resolves, with its #anchor, and
every `docs/<file>.md, "<heading>"` reference in the code names a real heading."""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])

def slug(heading):
    # GitHub's anchor: lowercase, punctuation dropped (hyphens kept), spaces to hyphens.
    text = re.sub(r"[`*_]", "", heading.strip().lower())
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")

def anchors(path):
    found, seen = set(), {}
    for line in path.read_text().splitlines():
        m = re.match(r"^#{1,6}\s+(.*)$", line)
        if not m:
            continue
        s = slug(m.group(1))
        n = seen.get(s, 0)
        found.add(s if n == 0 else f"{s}-{n}")
        seen[s] = n + 1
    return found

def headings(path):
    return {re.sub(r"[`*]", "", m.group(1)).strip() for m in re.finditer(r"^#{1,6}\s+(.*)$", path.read_text(), re.M)}

problems = []
pages = [root / "README.md", *sorted((root / "docs").glob("*.md"))]
for page in pages:
    text = re.sub(r"```.*?```", "", page.read_text(), flags=re.S)
    for target in re.findall(r"\]\(([^)\s]+)\)", text):
        if re.match(r"^[a-z]+:", target):
            continue
        file, _, anchor = target.partition("#")
        dest = (page.parent / file).resolve() if file else page
        if not dest.exists():
            problems.append(f"{page.relative_to(root)}: {target}: no such file")
        elif anchor and dest.suffix == ".md" and anchor not in anchors(dest):
            problems.append(f"{page.relative_to(root)}: {target}: no such heading")

for path in [p for d in ("bin", "lib", "host", "edge", "templates") for p in (root / d).rglob("*") if p.is_file()]:
    for doc, heading in re.findall(r'(docs/[a-z-]+\.md),\s*\\?"([^"\\]+)\\?"', path.read_text(errors="ignore").replace("\n# ", " ")):
        dest = root / doc
        if not dest.exists() or heading not in headings(dest):
            problems.append(f"{path.relative_to(root)}: {doc}, \"{heading}\": no such heading")
    for doc in re.findall(r"(docs/[a-z-]+\.md)", path.read_text(errors="ignore")):
        if not (root / doc).exists():
            problems.append(f"{path.relative_to(root)}: {doc}: no such file")

print("\n".join(problems))
sys.exit(1 if problems else 0)
