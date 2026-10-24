# PeSme/PatchMon fork

`main` here is **upstream `PatchMon/main` + a small stack of fork commits**, rebased
(never merged) so the fork stays a clean, readable diff on top of upstream:

| Commit | What |
| --- | --- |
| feat(hosts): standalone reboot action… | [PatchMon#855](https://github.com/PatchMon/PatchMon/pull/855), conflicts resolved against current main |
| feat(patching): policy-driven automated patching… (+2) | [PatchMon#856](https://github.com/PatchMon/PatchMon/pull/856) |
| fork: build/sync tooling | `fork/`, `.github/workflows/fork-*.yml` |

See the fork's changes at any time: `git log --oneline upstream/main..main`.

## What changed vs. the PRs as submitted

* **Migrations.** The PRs added `000042`/`000043`, numbers upstream has since used
  (main is at `000059`). golang-migrate keeps a single linear version, so any
  number the fork picks would eventually collide with an upstream one and be
  skipped silently. The schema changes therefore live in
  `server-source-code/internal/migrate/custom/*.sql`. These are idempotent
  `ADD COLUMN IF NOT EXISTS` files that run after the upstream migrations on
  every start (`custom.go`). The DB's migration version stays identical to
  upstream's, and the extra columns are harmless if you go back to the official
  image.
* **Reboot job** is resolved through `resolveDBForHost` like the other agent
  jobs on main, and it is skipped while a patch run is active.
* **sqlc code** was regenerated (sqlc v1.30.0) rather than hand-merged.

## Versioning

Images report `<next upstream patch>-pesme.<commits since last upstream release>`,
for example `2.1.7-pesme.16`:

* It sorts **above** the official 2.1.6, so agents on your hosts auto-update to the
  fork agent. That matters because both PRs change the agent: hosts need it for
  remote reboot and post-patch reboot.
* It sorts **below** the official 2.1.7, so once upstream releases, PatchMon's
  "update available" notice appears. That's your cue to sync.

## Image

GitHub Actions (`fork-image.yml`) builds on every push to `main` and publishes:

* `ghcr.io/pesme/patchmon-server:latest` (what the server runs)
* `ghcr.io/pesme/patchmon-server:<version>` and `:sha-<short>`, for pinning and rollback

The runtime base is upstream's `dhi.io/alpine-base` when the repo has
`DHI_USERNAME` / `DHI_TOKEN` secrets (a Docker Hub login with Docker Hardened
Images access). Without them, it is the official `ghcr.io/patchmon/patchmon-server:latest`,
which is built on that same hardened, non-root base.

Local build (same script as CI): `CONTAINER_CLI=podman BASE_IMAGE=ghcr.io/patchmon/patchmon-server:latest fork/build.sh`

## Updating when upstream moves

`fork-upstream-watch.yml` checks daily and opens an issue **"Upstream has new
commits"** saying whether the patches still rebase cleanly. To update:

```bash
cd ~/lab/patchmon
fork/sync.sh            # fetch upstream, rebase, vet/build checks, push --force-with-lease
gh run watch -R PeSme/PatchMon   # optional: watch the image build (~5 min)
```

The server picks up the new `:latest` at the next `podman-auto-update` run
(nightly). To apply it right away: `ssh apps@192.168.1.21 podman auto-update`.

If the rebase stops on a conflict:

```bash
git status                       # see what conflicts
fork/sync.sh --regen-sqlc        # for server-source-code/internal/db/*.go (generated): never hand-merge
# edit the remaining files, then
fork/sync.sh --continue          # continues the rebase, verifies, pushes
git rebase --abort               # or give up; main is untouched, and a backup/main-* branch is kept
```

`git rerere` is on, so any conflict you resolve once gets replayed automatically on
later syncs.

To track upstream **releases** instead of `main`: `fork/sync.sh --onto v2.1.7`.

**When upstream merges #855/#856 (or equivalents):** the rebase drops the fork
commits that became empty. If upstream ships the feature with real numbered
migrations, delete the matching `custom/*.sql` file in the same sync. The upstream
migration will use `IF NOT EXISTS`-style DDL, or will fail loudly on the existing
column. Check before deploying.

## Going back to the official image

Set `Image=ghcr.io/patchmon/patchmon-server:latest` in the quadlet and restart. The
extra columns don't bother upstream code. Two caveats:

* Agents stay on the fork version until upstream releases a higher one.
* If the fork was based on unreleased upstream `main` that included a new migration,
  the older official image fails its migration step (it does not know that DB version)
  until upstream releases that migration.
