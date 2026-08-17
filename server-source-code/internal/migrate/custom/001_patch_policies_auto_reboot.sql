-- Fork-only schema (PR #855/#856): reserved column for the policy-level
-- auto_reboot toggle. Lives outside migrations/ so it never takes a
-- golang-migrate version number that upstream may later claim; see custom.go.

ALTER TABLE patch_policies ADD COLUMN IF NOT EXISTS auto_reboot BOOLEAN NOT NULL DEFAULT false;
