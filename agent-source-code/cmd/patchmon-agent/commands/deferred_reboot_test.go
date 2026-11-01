package commands

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"patchmon-agent/internal/config"
)

func withTempConfigDir(t *testing.T) {
	t.Helper()
	m := config.New()
	m.SetConfigFile(filepath.Join(t.TempDir(), "config.yml"))
	prev := cfgManager
	t.Cleanup(func() {
		cfgManager = prev
		deferredRebootMu.Lock()
		if deferredRebootTimer != nil {
			deferredRebootTimer.Stop()
			deferredRebootTimer = nil
		}
		deferredRebootMu.Unlock()
	})
	cfgManager = m
}

func armedTimer() bool {
	deferredRebootMu.Lock()
	defer deferredRebootMu.Unlock()
	return deferredRebootTimer != nil
}

func TestResumePendingRebootRearmsFutureDeadline(t *testing.T) {
	withTempConfigDir(t)
	if err := writePendingReboot(pendingReboot{DueAt: time.Now().Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	resumePendingReboot()
	if !armedTimer() {
		t.Fatal("expected the deferred reboot to be re-armed")
	}
	if _, err := os.Stat(pendingRebootPath()); err != nil {
		t.Fatalf("pending file should stay until the reboot fires: %v", err)
	}
}

func TestResumePendingRebootDropsStaleDeadline(t *testing.T) {
	withTempConfigDir(t)
	if err := writePendingReboot(pendingReboot{DueAt: time.Now().Add(-2 * deferredRebootStaleAfter)}); err != nil {
		t.Fatal(err)
	}
	resumePendingReboot()
	if armedTimer() {
		t.Fatal("a long-overdue reboot must not be armed")
	}
	if _, err := os.Stat(pendingRebootPath()); !os.IsNotExist(err) {
		t.Fatalf("stale pending file should be removed, stat err=%v", err)
	}
}

func TestResumePendingRebootDiscardsGarbage(t *testing.T) {
	withTempConfigDir(t)
	if err := os.WriteFile(pendingRebootPath(), []byte("not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	resumePendingReboot()
	if armedTimer() {
		t.Fatal("garbage must not arm a reboot")
	}
	if _, err := os.Stat(pendingRebootPath()); !os.IsNotExist(err) {
		t.Fatalf("garbage file should be removed, stat err=%v", err)
	}
}
