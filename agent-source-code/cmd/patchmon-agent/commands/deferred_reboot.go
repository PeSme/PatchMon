package commands

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"

	"patchmon-agent/internal/system"
)

// Post-patch reboot after a policy-driven run (patch_policies.auto_reboot).
//
// The policy can postpone the reboot (auto_reboot_delay_minutes). When the
// delay expires the agent checks again whether the host still needs a reboot,
// so a VM that its hypervisor restarted in the meantime is not rebooted twice.
// The deadline is kept in a file next to config.yml so an agent restart (service
// restart, agent self-update) does not lose it. A host reboot clears the need
// itself, and the re-check then skips.

const (
	postPatchRebootReason          = "PatchMon post-patch reboot (policy)"
	maxPostPatchRebootDelayMinutes = 1440
	// A deadline missed by more than this (agent was down) is dropped instead of
	// rebooting the host at an unexpected time.
	deferredRebootStaleAfter = 30 * time.Minute
	// Re-check interval while a patch run is still in progress at the deadline.
	deferredRebootBusyRetry = 5 * time.Minute
)

type pendingReboot struct {
	DueAt time.Time `json:"due_at"`
}

var (
	deferredRebootMu    sync.Mutex
	deferredRebootTimer *time.Timer
)

func pendingRebootPath() string {
	return filepath.Join(filepath.Dir(cfgManager.GetConfigFile()), "pending-reboot.json")
}

// schedulePostPatchReboot reboots the host if it needs it, after delayMinutes.
// Delays of 1 minute or less keep the original behaviour: shutdown -r +1 now.
func schedulePostPatchReboot(delayMinutes int) {
	needs, reason := system.New(logger).CheckRebootRequired()
	if !needs {
		logger.Info("Post-patch reboot requested by policy but host does not need one; skipping")
		return
	}
	if delayMinutes > maxPostPatchRebootDelayMinutes {
		delayMinutes = maxPostPatchRebootDelayMinutes
	}
	if delayMinutes <= 1 {
		logger.WithField("reason", reason).Info("Post-patch reboot required by policy; scheduling reboot")
		if err := system.New(logger).ExecuteReboot(1, postPatchRebootReason); err != nil {
			logger.WithError(err).Warn("Post-patch reboot scheduling failed")
		}
		return
	}

	due := time.Now().Add(time.Duration(delayMinutes) * time.Minute).UTC()
	if err := writePendingReboot(pendingReboot{DueAt: due}); err != nil {
		logger.WithError(err).Warn("Could not persist the deferred reboot; it is lost if the agent restarts before it is due")
	}
	armDeferredReboot(due)
	logger.WithField("reason", reason).WithField("due_at", due.Format(time.RFC3339)).
		Info("Post-patch reboot deferred by policy; will reboot then if still required")
}

// resumePendingReboot re-arms a deferred reboot persisted by a previous agent process.
func resumePendingReboot() {
	data, err := os.ReadFile(pendingRebootPath())
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			logger.WithError(err).Warn("Could not read pending post-patch reboot")
		}
		return
	}
	var p pendingReboot
	if err := json.Unmarshal(data, &p); err != nil || p.DueAt.IsZero() {
		logger.Warn("Discarding unreadable pending post-patch reboot file")
		clearPendingReboot()
		return
	}
	if late := time.Since(p.DueAt); late > deferredRebootStaleAfter {
		logger.WithField("due_at", p.DueAt.Format(time.RFC3339)).Info("Dropping post-patch reboot that is long overdue")
		clearPendingReboot()
		return
	}
	armDeferredReboot(p.DueAt)
	logger.WithField("due_at", p.DueAt.Format(time.RFC3339)).Info("Resumed deferred post-patch reboot")
}

func armDeferredReboot(due time.Time) {
	// shutdown -r +1 adds the final minute (wall notice to logged-in users).
	wait := time.Until(due) - time.Minute
	if wait < 0 {
		wait = 0
	}
	setDeferredRebootTimer(wait)
}

func setDeferredRebootTimer(wait time.Duration) {
	deferredRebootMu.Lock()
	defer deferredRebootMu.Unlock()
	if deferredRebootTimer != nil {
		deferredRebootTimer.Stop()
	}
	deferredRebootTimer = time.AfterFunc(wait, fireDeferredReboot)
}

func fireDeferredReboot() {
	patchUpdateMu.Lock()
	busy := activePatchRuns > 0
	patchUpdateMu.Unlock()
	if busy {
		logger.Info("Deferred post-patch reboot is due but a patch run is in progress; re-checking in 5 minutes")
		setDeferredRebootTimer(deferredRebootBusyRetry)
		return
	}

	clearPendingReboot()
	needs, reason := system.New(logger).CheckRebootRequired()
	if !needs {
		logger.Info("Deferred post-patch reboot cancelled: host no longer needs a reboot")
		return
	}
	logger.WithField("reason", reason).Info("Deferred post-patch reboot is due and still required; scheduling reboot")
	if err := system.New(logger).ExecuteReboot(1, postPatchRebootReason); err != nil {
		logger.WithError(err).Warn("Post-patch reboot scheduling failed")
	}
}

func writePendingReboot(p pendingReboot) error {
	data, err := json.Marshal(p)
	if err != nil {
		return err
	}
	path := pendingRebootPath()
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func clearPendingReboot() {
	if err := os.Remove(pendingRebootPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		logger.WithError(err).Warn("Could not remove pending post-patch reboot file")
	}
}
