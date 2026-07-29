# Skills and plugins in the agent image

Everything below is baked into the container image, so it is available to every
tenant on a cold start with no download at runtime.

Two different mechanisms are in play, and it matters which is which:

| | What it is | Where it lives | Installed by |
|---|---|---|---|
| **Skill** | Instructions (and sometimes scripts) that teach the agent a workflow | `~/.openclaw/skills/@publisher/slug/` | `clawhub install` at build time |
| **Plugin** | Code that extends the gateway itself — model providers, channels, tools | `~/.openclaw/npm/projects/.../node_modules/` | `openclaw plugins install` at build time |

A skill cannot add a model provider, and a plugin is not prompt text. The Bedrock
provider is a plugin; the three items below are skills.

---

## Plugin: `@openclaw/amazon-bedrock-provider`

**This is what lets the agent talk to a model at all.** It registers the
`bedrock-converse-stream` provider that `openclaw.json` points at, authenticates
with the AWS SDK default credential chain (the AgentCore execution role), and
handles model discovery and embeddings.

You do not invoke it. It either registers at gateway start or every turn fails
with `LLM request failed`.

### The version pairing rule

Up to `openclaw@2026.5.7` the Bedrock provider was built into openclaw. From
`2026.6.x` it is this separate package, and **openclaw core no longer depends on
any AWS SDK**. Consequences:

- Installing openclaw alone leaves Bedrock unregistered. The gateway starts and
  looks healthy; every turn fails.
- The plugin declares `peerDependencies: { openclaw: ">=2026.6.33" }`.
- Both are pinned in the `Dockerfile` via `OPENCLAW_VERSION` and
  `BEDROCK_PROVIDER_VERSION`. **Bump them together, to the same version.**

The build fails loudly if the plugin does not register, so a mismatch cannot ship
silently.

`openclaw.json` also sets `plugins.allow: ["amazon-bedrock"]`, which explicitly
trusts this plugin. Without it the gateway warns that discovered plugins may
auto-load.

### Verify it

```bash
openclaw plugins list | grep -i amazon      # expect: enabled
openclaw models list  | grep -i bedrock     # expect: your BEDROCK_MODEL_ID
```

---

## Skill: `@parags/deep-research-pro@1.0.2`

**Multi-source web research producing a cited report.** Searches the web
(DuckDuckGo), fetches the most promising pages in full, synthesises findings, and
writes a structured report with sources.

- **No API key required.** Free, no signup.
- **How to use it:** ask in plain language — "research the current state of X and
  give me a cited report". The agent picks the skill up from the request; you do
  not name it.
- **What you get:** an executive summary plus a full report, written to a file
  when long, with a source list.
- **Cost:** just the model tokens for the turn. Research turns are long
  (many pages summarised), so they are among the most expensive turns you can run.

**Security note worth knowing:** the workflow fetches arbitrary web pages into the
agent's context. A hostile page can contain text aimed at the agent
(prompt injection). Since these agents also hold Gmail and Drive write scopes, treat
research output as untrusted input, and be deliberate about asking a research turn
to then act on your mailbox.

Why this publisher: several accounts publish a `deep-research-pro` slug with
byte-identical content. `@parags` is the original (created 2026-02, 35,433
downloads, ClawHub scan CLEAN, MIT-0); the others are later copies that receive no
updates.

---

## Skill: `@ericsantos/jina-reader@0.0.2`

**Clean extraction of a single web page or PDF** via the Jina AI Reader service —
turns a URL into readable text/Markdown, stripping navigation and ads. Much better
than raw HTML scraping when you want *one* document read accurately.

- **Needs `curl` and `jq`** — both present in the image.
- **Works with no key on the free tier** (10M tokens, no signup).
- **How to use it:** give the agent a URL — "read this page and summarise it",
  "extract the tables from this PDF".

Complementary to `deep-research-pro`: that one is breadth (many sources, synthesis),
this one is depth (one document, faithfully).

### Adding a paid API key

A key only raises rate and token limits; nothing breaks without one. Buy at
<https://jina.ai/reader/>, then pick **one** of these:

**Recommended — Secrets Manager, from the infra repo:**

```bash
just set-jina-key jina_xxxxxxxxxxxxxxxxxxxx   # stores openclaw/skills/jina
just deploy-phase2                            # pushes it to the runtime env
```

`scripts/cli.py` reads that secret and injects `JINA_API_KEY` into the runtime's
environment variables. `entrypoint.sh` then writes it to
`~/.config/jina/api_key` (mode 600) and exports it for the agent subprocess, so
the skill finds it either way. The secret accepts a bare key or
`{"apiKey": "jina_..."}`.

**Alternative — SSM, no redeploy:**

```bash
aws ssm put-parameter --type SecureString \
  --name /openclaw/OpenClaw/skill-keys/_global/JINA_API_KEY \
  --value jina_xxxxxxxxxxxxxxxxxxxx --overwrite
```

`skill_loader.py` reads `/openclaw/<STACK_NAME>/skill-keys/_global/*` on container
start and exports every parameter it finds into `/tmp/skill_env.sh`, which the
agent subprocess loads. Takes effect on the next cold start, no image rebuild and
no `deploy-phase2`.

**To remove it:** `just unset-jina-key` then `just deploy-phase2` (or delete the
SSM parameter). The skill silently returns to the free tier.

**Verify which tier is active** — the container logs one of these at startup:

```
[entrypoint] Jina Reader API key configured (paid tier limits apply)
[entrypoint] No JINA_API_KEY — jina-reader will use the free tier
```

---

## Skill: `@pskoett/self-improving-agent@4.0.1`

**A memory of mistakes.** The agent records corrections, errors, and discoveries
to `.learnings/` in its workspace, and consults them before later work. The intent
is that the same mistake is not repeated across sessions.

It has two parts, and both are active in this image:

1. **The skill** — tells the agent when to log a learning: a command failed, you
   corrected it ("no, that's wrong"), a capability was missing, an API broke, a
   better approach was found.
2. **The gateway hook** — `entrypoint.sh` runs `openclaw hooks enable
   self-improvement` and creates `.learnings/`. On agent bootstrap the hook injects
   a reminder to check existing learnings; when a session ends (`/new`, `/reset`)
   it sweeps that session's transcript for error patterns (`Error:`,
   `command not found`, `Traceback`, `npm ERR!`, …) and appends them to
   `.learnings/ERRORS.md` for triage.

### Files it maintains, in the workspace

| File | Contents |
|---|---|
| `.learnings/LEARNINGS.md` | Corrections, insights, knowledge gaps, best practices |
| `.learnings/ERRORS.md` | Auto-detected errors awaiting triage, deduplicated by pattern key |
| `.learnings/FEATURE_REQUESTS.md` | Capabilities the user asked for that do not exist |

### How to use it

Mostly you don't — it runs itself. What helps:

- **Correct the agent explicitly** when it is wrong ("no, the bucket is X"). That
  phrasing is one of its logging triggers.
- **Ask it to review learnings** before a big task: "check your learnings before
  you start".
- **Read `.learnings/LEARNINGS.md`** occasionally. It is a fair picture of where
  your agent keeps struggling.

### Data and privacy — read this

The session sweep writes **excerpts of real conversations** into the workspace,
which the S3 watchdog syncs to the tenant bucket. The skill truncates excerpts to
200 characters and redacts common secret shapes (bearer tokens, API keys, GitHub,
Slack and AWS tokens, JWTs) before writing, and only appends — it never rewrites
`ERRORS.md`. Even so, conversation fragments end up at rest in S3 under the
tenant's prefix. If that conflicts with your retention policy, disable it.

### Disabling it

```bash
SELF_IMPROVEMENT_DISABLED=1     # runtime env var: skips hook enable + .learnings/
```

Or delete `.learnings/` from the workspace — the sweep only runs when that
directory exists, which is the skill's own opt-in switch. To remove it entirely,
drop it from `SKILLS_PREINSTALL` and rebuild.

Why this publisher: five accounts publish this slug. ClawHub's scanner marks three
of them **SUSPICIOUS**. `@pskoett` is CLEAN, has 470,513 downloads, is
OpenClaw-specific, ships a test suite for its hook, and its handler imports only
`node:fs/promises` and `path` — no network, no subprocess.

---

## Also in the image (not a ClawHub skill)

**`gog` (gogcli)** — the Google Workspace CLI, installed as a Go binary and
credentialed at startup by `gog_init.py` from Secrets Manager. Gmail, Drive,
Calendar. Documented separately; the agent reaches it through shell, not a skill.

---

## Managing the set

Skills are chosen at **build** time by a Docker build arg:

```dockerfile
ARG SKILLS_PREINSTALL="@parags/deep-research-pro@1.0.2 @ericsantos/jina-reader@0.0.2 @pskoett/self-improving-agent@4.0.1"
ARG SKILLS_STRICT=1
```

Override without editing the file:

```bash
docker build --build-arg SKILLS_PREINSTALL="@parags/deep-research-pro@1.0.2" -t openclaw-agent .
```

### Two rules

**Always use a scoped, version-pinned name** — `@publisher/slug@version`.
Bare slugs are ambiguous now that multiple publishers own the same names;
`clawhub install deep-research-pro` exits non-zero listing candidates. Pinning the
version also stops skill content changing under you between builds of the same
commit.

**Leave `SKILLS_STRICT=1`.** A requested-but-missing skill fails the build. This
existed as a silent failure before: three of four skills were not installing, the
build exited 0 anyway, and the image shipped without them for months.

### Vetting a new skill before adding it

No ClawHub account is needed for any of this:

```bash
clawhub search "calendar"                       # find candidates + download counts
clawhub inspect @publisher/slug                 # owner, version, license, scan verdict
clawhub inspect @publisher/slug --files         # file list
clawhub inspect @publisher/slug --file SKILL.md # read the actual instructions
```

What to look at, in order: the **`Security`** line from `inspect` (CLEAN vs
SUSPICIOUS), download count relative to siblings sharing the slug, whether the
publisher is the original or a copy (compare `Created` dates and file hashes), and
whether it ships `scripts/` or `hooks/` — those execute, prompt-only skills do not.
`clawhub scan --slug` gives itemised findings but requires `clawhub login`.

### Verify what a running container has

```bash
openclaw skills list      # expect all three, "✓ ready", source openclaw-managed
openclaw plugins list     # expect amazon-bedrock enabled
```

At build time the same information appears in the log:

```
[skills] installed: @parags/deep-research-pro @ericsantos/jina-reader @pskoett/self-improving-agent
```
