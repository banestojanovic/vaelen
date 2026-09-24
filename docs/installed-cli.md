# Installed `val` CLI

`Scripts/install-cli.sh` builds the Release `val` executable and installs a
stable user-owned copy at:

```text
~/Library/Application Support/Vaelen/bin/val
```

It places a symlink at `~/.local/bin/val`. That directory must already be on
the shell's PATH; the installer deliberately does not edit shell configuration.
The PHP shell resolver is a separate executable in the same support `bin`
directory and is not replaced by this installer.

The installed CLI is a copy, not a link into `.build`. A checksum record marks
the copy as installer-managed and is checked before upgrades. Unknown files,
modified installed copies, and unrelated command symlinks are refused. The
currently recognized legacy migration is the Vaelen development link created
by the tracked `Scripts/install-dev-cli.sh` in `~/Code/apps/vaelen`; before
migration, the installer preserves that symlink as
`~/.local/bin/val.vaelen-dev-backup-<timestamp>`.

Run the installer again to upgrade from the current checkout's Release build.
It verifies the candidate's product version and build identity against the
installed app and embedded Core, and is idempotent when the candidate is
unchanged. `Scripts/install-dev-cli.sh` remains available for development-only
links and should not be used for the user-facing installed command.
