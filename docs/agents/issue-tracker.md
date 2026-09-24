# Issue tracker: Local Markdown

Issues and specs for this repo live as markdown files in `.scratch/`.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`
- The spec is `.scratch/<feature-slug>/spec.md`
- Implementation issues are one file per ticket at `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`, never a single combined tickets file
- Triage state is recorded as a `Status:` line near the top of each issue file (see `triage-labels.md` for the role strings). Note: `Status:` is **overloaded** across efforts — in this repo it also records wayfinding states (`claimed`/`resolved`/`done`) for `/wayfinder` (see "Wayfinding operations" below), so a ticket can carry both a triage role (in the label) and a wayfinding state (in `Status:`). Prefer putting the triage role in a `Triage:` label (the five canonical labels), keeping `Status:` for the wayfinding state machine.
- Comments and conversation history append to the bottom of the file under a `## Comments` heading

## When a skill says "publish to the issue tracker"

Create a new file under `.scratch/<feature-slug>/` (creating the directory if needed).

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user will normally pass the path or the issue number directly.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a file with one **child** file per ticket.

- **Map**: `.scratch/<effort>/map.md` (the Notes / Decisions-so-far / Fog body). The map usually sits in the effort root, but `bg3-neuro-implementation` keeps it at `issues/map.md` (no root `map.md`) — both are acceptable. `spec.md` is created by `/to-spec` and is present only where a spec was produced (e.g. `bg3-neuro-perception`), not in every effort.
- **Child ticket**: `.scratch/<effort>/issues/NN-<slug>.md`, numbered from `01`, with the question in the body. A `Type:` line records the ticket type (`research`/`prototype`/`grilling`/`task`, plus the types actually used in this repo: `bug`, `implementation`, `feature`, `research-findings`, `task (live bench)`); a `Status:` line records `claimed`/`resolved`.
- **Blocking**: a `Blocked by: NN, NN` line near the top. A ticket is unblocked when every file it lists is `resolved`.
- **Frontier**: scan `.scratch/<effort>/issues/` for files that are open, unblocked, and unclaimed; first by number wins.
- **Claim**: set `Status: claimed` and save before any work.
- **Resolve**: append the answer under an `## Answer` heading, set `Status: resolved`, then append a context pointer (gist + link) to the map's Decisions-so-far in `map.md`.