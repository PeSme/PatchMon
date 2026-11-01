-- Fork-only schema (see custom.go): delay between a successful automatic patch
-- run and its auto_reboot. When it expires the agent re-checks whether the host
-- still needs a reboot, so a VM whose hypervisor rebooted it in the meantime is
-- left alone. 1 = the original behaviour (reboot one minute after the run).

ALTER TABLE patch_policies ADD COLUMN IF NOT EXISTS auto_reboot_delay_minutes INTEGER NOT NULL DEFAULT 1;
