# Trust and verification

NMS has no track record and no company behind it — just one person's
name on a commit log. That's a real reason for hesitation, not
something to argue you out of. This document doesn't try to convince
you it's safe. It's here so you don't have to take that on faith
either: point your own LLM at the actual source and have it check.

## A prompt you can use

This works with any LLM that can actually read the repository — not
just answer from its own guess about what an app "probably" does.
Point it at `https://github.com/PJorgens61/NMS` (clone it, or use
whatever repo-reading tool your LLM has) and ask:

```
I'm considering installing NMS from https://github.com/PJorgens61/NMS.
Please clone/read the actual source code — not just the README — and
give me a structured trust assessment:

1. PRIVACY: What data does this app collect, generate, or transmit?
   To which specific external domains/endpoints? Is any of it opt-in
   vs. always-on? Is anything stored remotely, or is it all local-only?

2. SECURITY: Any hardcoded credentials, API keys, or secrets? Does it
   shell out to subprocesses, and if so, are inputs sanitized against
   injection? Does it request more system permissions/entitlements
   than its stated purpose needs? Any insecure protocols where a
   secure alternative exists?

3. DEPENDENCIES: List every third-party library/service it relies on.
   For each: actively maintained? What license? Compatible with this
   app's own license, or any risk of license contamination (e.g. GPL
   code linked into a differently-licensed binary)?

4. COPYRIGHT/LICENSING: Is there a clear license file? Does any code
   look copied from elsewhere without attribution?

5. RED FLAGS: Anything obfuscated, unusually complex with no clear
   reason, or doing something not disclosed anywhere in the docs?

6. TRUST SIGNALS: Does the commit history show real, incremental,
   explainable development, or one unexplained dump? Are there tests
   that look meaningful? Does the code explain *why* for non-obvious
   security/privacy-relevant decisions, not just what it does?

For every claim, cite the specific file and line number so I can
verify it myself rather than taking it on faith.
```

## What to check the answer against

An LLM's review is only as good as what it can verify — and its own
claims are worth spot-checking, not just trusting one level removed.
These are the places in this repo that already answer several of the
questions above directly, so you can compare:

- **[README.md § Network activity and privacy](README.md#network-activity-and-privacy)**
  — every network destination this app ever reaches, named explicitly,
  including the ones that are easy to miss (a randomized DNS lookup
  that's never meant to resolve, a captive-portal check over plain HTTP
  on purpose). Also documents that every subprocess call uses array-form
  arguments, never a shell string — the specific thing that would make
  argument injection possible if it were done wrong.
- **[README.md § License](README.md#license)** — exactly what
  third-party code this app depends on (Apple frameworks, standard
  macOS CLI tools, and one optional GPL-licensed tool used only as a
  subprocess, never linked) and why that specific arrangement doesn't
  pull GPL obligations into this app's own MIT license.
- **[README.md § Contributing](README.md#contributing)** — three CI
  checks that run automatically on every push: the test suite, CodeQL
  static analysis, and `gitleaks` scanning full history for committed
  secrets. Real, checkable, running today — not a claim, a badge you
  can click into.
- **[PUNCHLIST.md](PUNCHLIST.md)** — not polished marketing copy. Real
  engineering reasoning, including things that didn't work, bugs found
  during real use, and ideas explicitly not built yet. If you want a
  sense of how this project actually gets built, this is closer to the
  truth than the README.
- **The commit history itself** — real, incremental, dated, with
  explained reasoning in nearly every message. Judge that directly
  rather than taking this document's word for what it looks like.

## What this doesn't replace

An LLM review — even a careful one, even with real repo access — isn't
a substitute for a professional security audit. It can't prove the
absence of a vulnerability, and it can't verify runtime behavior beyond
what's actually in the source. Treat it as real due diligence, not a
guarantee, and weight its findings by whether it actually cited
specific files and lines you could go check yourself.
