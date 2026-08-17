package migrate

import (
	"context"
	"embed"
	"fmt"
	"io/fs"
	"sort"

	"github.com/jackc/pgx/v5"
)

// Fork-only schema changes live in custom/ instead of migrations/.
//
// golang-migrate tracks a single linear version, so a fork migration numbered
// 000060 would collide with (or silently shadow) whatever upstream ships as
// 000060 next. Instead, every custom/*.sql file is re-applied after the
// upstream migrations on every start, so each file must be idempotent
// (ADD COLUMN IF NOT EXISTS, CREATE INDEX IF NOT EXISTS, ...). The database's
// golang-migrate version stays identical to upstream's, and the extra columns
// are harmless if the official image is run against the same database.
//
//go:embed custom/*.sql
var customFS embed.FS

func runCustom(databaseURL string) error {
	files, err := fs.Glob(customFS, "custom/*.sql")
	if err != nil {
		return fmt.Errorf("list custom migrations: %w", err)
	}
	if len(files) == 0 {
		return nil
	}
	sort.Strings(files)

	ctx := context.Background()
	conn, err := pgx.Connect(ctx, databaseURL)
	if err != nil {
		return fmt.Errorf("custom migrations: connect: %w", err)
	}
	defer func() { _ = conn.Close(ctx) }()

	for _, f := range files {
		sql, err := customFS.ReadFile(f)
		if err != nil {
			return fmt.Errorf("custom migrations: read %s: %w", f, err)
		}
		if _, err := conn.Exec(ctx, string(sql)); err != nil {
			return fmt.Errorf("custom migrations: apply %s: %w", f, err)
		}
	}
	_, _ = fmt.Printf("[migrate] applied %d custom (fork) migration(s)\n", len(files))
	return nil
}
