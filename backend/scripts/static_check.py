#!/usr/bin/env python3
"""Static safety checks for the DWLY EGY database migrations and repo.

This is NOT a database run. It parses the SQL text and catches structural mistakes
(missing RLS, risky grants, unpinned search_path, bad FK order, committed secrets...).
Real behaviour is tested by supabase/tests/database/*.test.sql with `supabase test db`.
"""
import hashlib, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parents[2]          # DWLY_EGY/
SUPA = ROOT / "backend" / "supabase"
results = []                                                  # (ok, message)

def check(ok, msg):
    results.append((bool(ok), msg))

def strip_comments(sql):
    sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.S)
    return re.sub(r"--[^\n]*", "", sql)

files = sorted((SUPA / "migrations").glob("*.sql"))
raw = {f.name: f.read_text(encoding="utf-8") for f in files}
sql = "\n".join(strip_comments(t) for t in raw.values())

# 1. migration numbering
nums = [int(n.split("_")[0]) for n in raw]
check(nums == list(range(1, len(nums) + 1)), f"migrations numbered 1..{len(nums)} without gaps")

# 2. tables, RLS, policies
tables = re.findall(r"create table public\.(\w+)", sql)
check(len(tables) == len(set(tables)), f"{len(tables)} public tables, no duplicates")
rls = set(re.findall(r"alter table public\.(\w+)\s+enable row level security", sql))
for t in tables:
    check(t in rls, f"RLS enabled on public.{t}")
policies = re.findall(r"create policy (\w+|\"[^\"]+\")\s+on\s+([\w.]+)\s+for\s+(\w+)\s+to\s+([\w, ]+?)\s+(using|with check)", sql)
by_table = {}
for name, tbl, cmd, roles, _ in policies:
    by_table.setdefault(tbl.replace("public.", ""), []).append((name, cmd, roles))
for t in tables:
    check(t in by_table, f"public.{t} has at least one policy")

# 3. no permissive write policies (allowlist: newsletter signup insert)
stmts = re.findall(r"create policy .*?;", sql, flags=re.S)
for s in stmts:
    m = re.search(r"on\s+([\w.]+)\s+for\s+(\w+)", s)
    tbl, cmd = m.group(1), m.group(2)
    using = re.search(r"using\s*\((.*?)\)\s*(with check|;)", s, flags=re.S)
    wcheck = re.search(r"with check\s*\((.*)\)\s*;", s, flags=re.S)
    if cmd in ("insert", "update", "delete", "all"):
        bad = (using and using.group(1).strip() == "true") or (wcheck and wcheck.group(1).strip() == "true")
        allowed = tbl == "public.newsletter_subscribers" and cmd == "insert"
        check(not bad or allowed, f"policy on {tbl} ({cmd}) is not unconditionally true")
    if cmd in ("insert", "update", "delete", "all") and re.search(r"\bto\b[^;]*\banon\b", s) and tbl != "public.newsletter_subscribers":
        check(False, f"policy on {tbl} ({cmd}) must not be open to anon")

# 4. SECURITY DEFINER functions pin search_path
funcs = re.split(r"(?=create or replace function )", sql)[1:]
for f in funcs:
    name = re.match(r"create or replace function ([\w.]+)", f).group(1)
    head = f.split("as $$")[0]
    if "security definer" in head:
        check("set search_path" in head, f"{name}: SECURITY DEFINER pins search_path")

# 5. grants: nothing broad to anon; sensitive tables have no client writes
for g in re.findall(r"grant [^;]*? to [^;]*;", sql):
    if re.search(r"\bto\b[^;]*\banon\b", g):
        ok = (g.strip().startswith("grant select") or g.strip().startswith("grant execute on function private.")
              or g.strip().startswith("grant usage on schema private") or "newsletter_subscribers" in g)
        check(ok, "anon grant is read-only (or newsletter insert): " + re.sub(r"\s+", " ", g)[:70])
    check("grant all" not in g.lower(), "no 'grant all': " + re.sub(r"\s+", " ", g)[:50])
no_client_writes = ["orders","order_items","order_status_history","payments","payment_transactions",
                    "inventory","inventory_movements","carts","discount_redemptions","roles"]
for t in no_client_writes:
    leaked = [g for g in re.findall(r"grant\s+(?:insert|update|delete)[^;]*;", sql)
              if re.search(rf"public\.{t}\b", g)]
    check(not leaked, f"no client INSERT/UPDATE/DELETE grant on public.{t}")
check(re.search(r"grant execute on function public\.record_payment_event\([^)]*\)\s+to service_role", sql)
      and not re.search(r"grant execute on function public\.record_payment_event[^;]*(authenticated|anon)", sql),
      "record_payment_event is service_role only")
check("revoke execute on all functions in schema private" in sql, "private functions revoked from clients by default")

# 6. FK targets exist and are created earlier
pos = {t: sql.index(f"create table public.{t}") for t in tables}
for m in re.finditer(r"create table public\.(\w+)(.*?)\n\);", sql, flags=re.S):
    me, body = m.group(1), m.group(2)
    for ref in re.findall(r"references public\.(\w+)", body):
        check(ref in pos and (pos[ref] < pos[me] or ref == me), f"FK {me} -> {ref} refers to an earlier table")

# 7. money columns carry CHECK constraints
for m in re.finditer(r"create table public\.(\w+)(.*?)\n\);", sql, flags=re.S):
    for line in m.group(2).splitlines():
        if re.search(r"numeric\(\d+,\d+\)", line):
            check("check" in line.lower(), f"{m.group(1)}: numeric column has CHECK: " + line.strip()[:50])

# 8. seed hygiene and demo flag
seed = strip_comments((SUPA / "seed.sql").read_text(encoding="utf-8"))
check("is_demo = false" not in seed, "seed never creates non-demo rows")
check(re.search(r"\) as v\(slug", seed) and ", true" in seed, "seed products inserted with is_demo = true")
check("'DEMO-'" in seed, "demo SKUs are prefixed DEMO-")

# 9. secrets
secret_pats = [r"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}", r"sk_(live|test)_[A-Za-z0-9]{10,}", r"-----BEGIN [A-Z ]*PRIVATE KEY-----"]
leak = []
for f in ROOT.rglob("*"):
    if f.is_file() and f.suffix in {".sql",".ts",".tsx",".js",".json",".md",".env",".example",".toml",".py",".html"} or f.name.startswith(".env"):
        try: txt = f.read_text(encoding="utf-8")
        except Exception: continue
        if f.name == "static_check.py": continue
        if any(re.search(p, txt) for p in secret_pats): leak.append(str(f.relative_to(ROOT)))
check(not leak, "no JWT-like keys / private keys in repo" + (f" ({leak})" if leak else ""))
env = (ROOT / ".env.example").read_text(encoding="utf-8")
vals = [l.split("=",1)[1].strip() for l in env.splitlines() if "=" in l and not l.startswith("#")]
filled = [l for l in env.splitlines() if re.match(r"[A-Z_]*(KEY|SECRET)[A-Z_]*=\S+", l)]
check(not filled, ".env.example has no filled-in secrets")
check(not re.search(r"VITE_\w*(SERVICE|SECRET)", env), "no secret variable has a VITE_ prefix")
check(".env" in (ROOT / ".gitignore").read_text(), ".env is git-ignored")

# 10. original V1 preserved byte-for-byte
v1 = ROOT / "original" / "DWLY_EGY_V1.html"
want = (ROOT / "docs" / "V1.sha256").read_text().split()[0]
check(v1.exists() and hashlib.sha256(v1.read_bytes()).hexdigest() == want, "original/DWLY_EGY_V1.html matches recorded SHA-256")

fails = [m for ok, m in results if not ok]
verbose = "--verbose" in sys.argv
for ok, m in results:
    if verbose or not ok:
        print(("PASS  " if ok else "FAIL  ") + m)
print(f"\n{len(results)-len(fails)} passed, {len(fails)} failed")
sys.exit(1 if fails else 0)
