# Trust and verification

NMS has no track record and no company behind it — just one person's
name on a commit log. That's a real reason for hesitation, not
something to argue you out of. This document doesn't try to convince
you it's safe. It's here so you don't have to take that on faith
either: point your own LLM at the actual source and have it check.

This version folds in what several actual audits against this repo
turned up — a static privacy/security review, a full six-question
trust assessment, and a live network-traffic capture (all in
[docs/reviews/](docs/reviews/)) — plus what an enterprise's legal/
procurement review tends to ask that an individual reader usually
doesn't. If you're evaluating this for personal use, the first prompt
below is enough. If you're clearing it for use inside an organization,
also read "For enterprise or legal review."

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
   Enumerate every hardcoded network endpoint in the source (not just
   what the README claims), and categorize each by purpose. Grep for
   known telemetry/analytics/crash-reporting SDK names (firebase,
   sentry, mixpanel, amplitude, crashlytics, segment, bugsnag,
   appcenter, etc.) and confirm none are present. Is any of it opt-in
   vs. always-on? Is anything stored remotely, or is it all local-only?
   If a feature only needs to confirm reachability (a status code),
   does it actually avoid downloading the full response body, or does
   it fetch more than it needs?

2. SECURITY: Any hardcoded credentials, API keys, or secrets? Does it
   shell out to subprocesses, and if so, are inputs sanitized against
   injection — specifically, does every subprocess call use array-form
   arguments rather than a shell string? Does it request more system
   permissions/entitlements than its stated purpose needs? Any insecure
   protocols where a secure alternative exists (and if so, is the
   insecurity actually necessary for what's being checked, or just
   sloppy)? Where credentials/secrets ARE stored, does the storage
   mechanism match the actual risk level of what's being protected —
   and if it doesn't, is that a documented, reasoned tradeoff or an
   unexplained gap?

3. DEPENDENCIES: List every third-party library/service it relies on.
   Don't take a "zero dependencies" claim on faith — verify it directly
   against the actual package manifest / build configuration (e.g. no
   Package.swift/Package.resolved, no dependency entries in the project
   file). For each real dependency: actively maintained? What license?
   Compatible with this app's own license, or any risk of license
   contamination (e.g. GPL code linked into a differently-licensed
   binary)?

4. COPYRIGHT/LICENSING: Is there a clear license file? Does any code
   look copied from elsewhere without attribution?

5. PLATFORM SANDBOXING / PRIVILEGE: What OS-level sandbox or
   entitlements does this app run under? If sandboxing is disabled or
   entitlements are broad, is there a stated reason tied to what the
   app actually needs to do? What would that mean in practice for what
   this app could access if it were ever compromised or malicious?

6. FEATURE SAFETY SCOPING: For any feature capable of affecting
   something beyond the user's own device — active network scanning,
   load/stress testing, probing arbitrary hosts, forcing a network
   reconfiguration — is it scoped to safe defaults (e.g. the user's own
   gateway, not an arbitrary address) and gated behind an explicit
   confirmation, not silently available?

7. RED FLAGS: Anything obfuscated, unusually complex with no clear
   reason, or doing something not disclosed anywhere in the docs?
   Specifically check for authentication/OAuth code, sign-in flows, or
   anything suggesting a not-yet-shipped feature that would change the
   answers above once it lands.

8. TRUST SIGNALS: Does the commit history show real, incremental,
   explainable development, or one unexplained dump? Are there tests
   that look meaningful? Does the code explain *why* for non-obvious
   security/privacy-relevant decisions, not just what it does?

9. VALIDITY BOUNDARY: State the exact commit hash your findings are
   based on — a static source read is a snapshot, not a permanent
   verdict. If you have the ability to run commands (not just read
   files), also do a brief live capture of the app's actual network
   traffic while it runs (tcpdump, nettop, or equivalent — no special
   tooling required on macOS, and no root/sudo needed if the account is
   in the access_bpf group). A source read tells you what's *supposed*
   to happen; a live capture can catch what actually does, including a
   feature that quietly does more than its own code comments suggest.

For every claim, cite the specific file and line number (or the exact
command and its output, for anything checked at runtime) so I can
verify it myself rather than taking it on faith.
```

## If your LLM says the repo doesn't exist or is private

It's public — `https://github.com/PJorgens61/NMS` returns HTTP 200 to a
plain, anonymous, unauthenticated request, both the repo page itself and
the raw README. If an LLM tells you otherwise, that's not a finding
about this repo — it's a sign that LLM doesn't actually have live
web/repo access in whatever mode you're using, and rather than saying
so, it fabricated a plausible-sounding but false explanation instead.
Confirmed live: this happened with a real model during this document's
own writing.

**Before trusting any LLM's verdict on this repo (or any repo), confirm
it actually fetched something real** — ask it something a guess
couldn't answer correctly, like the exact SHA of the latest commit on
`main`, or the literal first sentence of `README.md`. If it can't answer
that correctly, it didn't really read the repository, and nothing else
it told you about privacy, security, or dependencies came from the
actual source either — no matter how confident or specific it sounded.
Different products vary in whether this needs to be explicitly turned
on: a coding-agent-style tool that can actually `git clone` will have
real access by default; a plain chat interface often needs a specific
browsing/repo-connector feature enabled first, and won't always tell you
when it's missing.

## What to check the answer against

An LLM's review is only as good as what it can verify — and its own
claims are worth spot-checking, not just trusting one level removed.
These are the places in this repo that already answer several of the
questions above directly, so you can compare:

- **[docs/reviews/](docs/reviews/)** — actual completed audits against
  this repo, each dated and tied to a specific commit: a static
  privacy/security review, a full six-question trust assessment run
  against this exact prompt, and a live network-traffic capture. Read
  these before assuming your own LLM found something new — and don't
  assume they're still current either; check the commit hash each one
  cites against `main`'s latest.
- **[script/privacy-security-check.sh](script/privacy-security-check.sh)**
  — the greps behind those reviews, automated and diffed against a
  checked-in baseline. Needs nothing but a shell; run it yourself
  rather than trusting either this document or an LLM's summary of it.
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

## For enterprise or legal review

An individual reader mostly cares whether this app is safe to run on
their own Mac. A General Counsel or procurement reviewer clearing it
for use inside an organization is usually asking a different, more
specific set of questions — some of which no code read, by an LLM or a
human, can actually answer. Naming both kinds plainly:

**Questions a source read can answer:**

- **Data residency.** Does any internally-discovered data — LAN device
  names, IP addresses, SNMP community strings, network topology — ever
  get included in an *outbound* request to a third party, as opposed to
  staying local? This is a narrower, sharper version of the PRIVACY
  question above, worth asking explicitly: the general "what does it
  send externally" answer can be technically correct while still
  leaving this specific concern unstated.
- **Regulated data flows.** The public IP lookup
  (`api.ipify.org`, see README's Network activity section) sends this
  Mac's public IP address to a third party on a background timer —
  under GDPR and similar regimes, an IP address is generally treated as
  personal data. That's the one outbound data point in this app closest
  to a real "personal data leaves the device" answer; everything else
  documented in that section is either a reachability check with no
  payload, or user-triggered.
- **Update mechanism.** Confirmed directly (`grep`-searched for
  Sparkle/`SUUpdater`/any auto-update framework — none found): NMS has
  **no auto-update mechanism**. Nothing phones home to check for or
  fetch a new version automatically. Updates require manually
  downloading a new signed, notarized build (see README's "Signed and
  notarized releases") — no supply-chain-on-update vector exists
  because there's no update channel to compromise.
- **Liability/warranty disclaimer.** Confirmed present and unmodified:
  `LICENSE` contains the MIT template's standard disclaimer clause
  verbatim — `THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
  KIND, EXPRESS OR...` — nothing was edited out of the standard text
  that would otherwise apply.
- **Vendor risk / support model.** One maintainer, no company, no
  support contract, no SLA on patching a reported vulnerability. This
  is the thing this document opens with — worth restating in
  procurement terms: there is no vendor to hold to a response-time
  commitment, only a public issue tracker.

**Questions a source read cannot answer — flag these to counsel
directly rather than expecting an LLM's summary to resolve them:**

- **Clear title to license.** MIT licensing requires the licensor to
  actually hold the rights being granted. Nothing in the source can
  confirm whether this was written entirely on the author's own time
  and equipment versus under an employer's IP-assignment terms — that's
  a representation only the author can make, not something a code read
  establishes.
- **Formal indemnification.** MIT's disclaimer (see above) is standard
  for open-source software and means, by design, no indemnification is
  offered. This isn't a defect specific to this project — it's true of
  the overwhelming majority of open-source dependencies any
  organization already runs — but it's worth stating plainly rather
  than assuming a clean trust-assessment result implies otherwise.
- **Export control classification.** Not evaluated here. NMS's own
  network operations (ping, traceroute, SNMP, HTTPS via system
  frameworks) don't implement cryptography of their own — they rely on
  the OS's TLS stack — which is the usual basis for such software being
  out of scope, but that determination is a legal one to make formally,
  not something this document or an LLM should be treated as having
  already settled.

## What this doesn't replace

An LLM review — even a careful one, even with real repo access — isn't
a substitute for a professional security audit, and it isn't a
substitute for actual legal or compliance sign-off either. It can't
prove the absence of a vulnerability, it can't verify runtime behavior
beyond what's actually in the source unless it was run with real
command access (see "VALIDITY BOUNDARY" above), and it can't make legal
representations on anyone's behalf. Treat it as real due diligence, not
a guarantee, and weight its findings by whether it actually cited
specific files and lines — or specific commands and output — you could
go check yourself.
