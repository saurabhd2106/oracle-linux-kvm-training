# OCI CLI Installer Scripts

This folder contains OS-specific scripts for installing Oracle Cloud Infrastructure CLI.

The scripts use Oracle's official OCI CLI installers and do not store or request OCI credentials.

## Files

- `install-oci-cli-linux.sh`: Linux Bash installer
- `install-oci-cli-macos.sh`: macOS Bash installer
- `install-oci-cli-windows.ps1`: Windows PowerShell installer

## Linux

Run from the repository root:

```sh
bash install-oci-cli/install-oci-cli-linux.sh
```

The script requires:

- `bash`
- `curl`
- `python3`

## macOS

Run from the repository root:

```sh
bash install-oci-cli/install-oci-cli-macos.sh
```

The script requires:

- `bash`
- `curl`
- `python3`

If `oci` is not immediately available after install, add this to your shell profile and open a new terminal:

```sh
export PATH="$HOME/bin:$PATH"
```

For macOS zsh, use `~/.zshrc`. For bash, use `~/.bash_profile` or `~/.bashrc`.

For the current terminal only, run:

```sh
export PATH="$HOME/bin:$PATH"
```

Then verify:

```sh
oci --version
```

If the installer reports that `~/lib/oracle-cli` already exists, it is usually a partial or previous install. Re-run with explicit cleanup:

```sh
OCI_CLI_REMOVE_EXISTING=true ./install-oci-cli-macos.sh
```

Or remove the previous install manually before running the script again:

```sh
rm -rf "$HOME/lib/oracle-cli"
./install-oci-cli-macos.sh
```

## Windows

Run PowerShell as your normal user and execute:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-oci-cli\install-oci-cli-windows.ps1
```

If your organization blocks script execution, set the current-user policy before running:

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

## Custom Installer Arguments

By default, the scripts run Oracle's installer with:

```text
--accept-all-defaults
```

For Linux/macOS, override this with:

```sh
OCI_CLI_INSTALLER_ARGS="--accept-all-defaults" bash install-oci-cli/install-oci-cli-linux.sh
```

For Windows, pass a custom argument string:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-oci-cli\install-oci-cli-windows.ps1 -InstallerArguments "--accept-all-defaults"
```

## Verify Installation

Check the installed CLI version:

```sh
oci --version
```

If that fails on Linux or macOS but the installer reported success, try the full path:

```sh
$HOME/bin/oci --version
```

If `~/lib/oracle-cli` already exists on Linux, use:

```sh
OCI_CLI_REMOVE_EXISTING=true ./install-oci-cli-linux.sh
```

On Windows PowerShell:

```powershell
oci --version
```

## Authenticate OCI CLI

After installing the CLI, configure authentication:

```sh
oci setup config
```

The command asks for:

- Tenancy OCID
- User OCID
- Region
- API private key location
- API key passphrase, if configured

Upload the generated public API key in OCI Console:

```text
Profile > My Profile > API Keys > Add API Key
```

Then verify authentication:

```sh
oci iam region list
```

## Safety Notes

- Do not commit OCI private keys, generated config files, or credential values.
- The installer scripts do not embed tenancy OCIDs, user OCIDs, fingerprints, private keys, or passwords.
- Review Oracle's official installer output before accepting changes to shell profiles or PATH.
