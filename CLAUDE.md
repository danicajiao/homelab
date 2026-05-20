# homelab — Claude Context

## Project Overview

GitOps repository for a single-node K3s homelab cluster managed by Argo CD. All changes land on `main` via PR — Argo CD reconciles within ~3 minutes of a merge. No hotpatching; every change goes through the PR → CI → merge → reconcile flow.

**Related repo:** `danicajiao/cove` — the iOS app and backend services whose Kubernetes manifests live here.

---

## Git Workflow

### Switching branches

Always `git pull` immediately after switching to an existing branch. `main` receives merges frequently; starting from a stale copy causes avoidable conflicts.

```bash
git checkout main
git pull  # always — before touching anything
```

### Creating branches

Always set the remote upstream on the first push (`-u`). This lets subsequent `git pull` and `git push` calls work without specifying the remote explicitly.

```bash
git checkout -b fix/234-staging-subdomain
# ... commit changes ...
git push -u origin fix/234-staging-subdomain  # -u on first push, always
```

---

## Branch Naming

Format: `<label>/<REPO>-<issue-number>-<short-description-in-kebab-case>`

When no GitHub issue exists for the change, omit the `<REPO>-<issue-number>` segment:
`<label>/<short-description-in-kebab-case>`

The `<REPO>` prefix is always ALL CAPS. All infrastructure work is tracked in `danicajiao/cove`, so the prefix is always `COVE` — even though the branch lives in this repo.

| Label | Use |
|---|---|
| `feature/` | New manifests or capabilities |
| `enhancement/` | Improvements to existing manifests |
| `bug/` | Fixes to broken manifests or config |
| `docs/` | Documentation-only changes |
| `chore/` | Maintenance, operator bumps, tooling |

Examples — with issue:
- `feature/COVE-234-cloudflare-tunnel-routing`
- `bug/COVE-234-staging-subdomain-single-level`

Examples — no issue (off-cycle fixes):
- `chore/bump-cloudflared-2026-6`
- `docs/update-secrets-runbook`

---

## Commit Messages

Imperative mood, sentence case. Same convention as `danicajiao/cove`.

```
Route cove-api traffic through Cloudflare Tunnel
```

- Start with a verb: `Add`, `Update`, `Fix`, `Refactor`, `Remove`
- Keep the subject line under 72 characters

---

## Cross-Repo References

This repo and `danicajiao/cove` reference each other frequently. A bare `#number` in a PR or issue body resolves within the repo it lives in. **Always use the fully qualified `owner/repo#number` format when referencing across repos.**

| Situation | Correct | Wrong |
|---|---|---|
| Referencing a cove issue from a homelab PR | `danicajiao/cove#234` | `#234` |
| Referencing a homelab PR from a cove PR | `danicajiao/homelab#28` | `#28` |

Note: `Closes owner/repo#N` does **not** auto-close cross-repo — GitHub only auto-closes issues in the same repo. Cross-repo references are documentation only.

---

## How Deploys Work

1. Open a PR with manifest changes
2. CI runs `kubectl kustomize` + `kubeconform` schema validation
3. Merge to `main`
4. Argo CD reconciles within ~3 minutes (or click **Hard Refresh** in the UI)

There are no environment-specific branches — `main` is the single source of truth. Staging vs prod differences are expressed entirely through Kustomize overlays.

---

## GitHub Operations

All GitHub interactions must go through the `gh` CLI. Never use MCP GitHub plugin tools.

```bash
gh pr create --title "..." --body "..."
gh issue view 234 --repo danicajiao/cove
gh pr edit 28 --body "..."
```
