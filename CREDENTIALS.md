# Credentials inventory, storage locations and rotation

This playbook creates several credentials by design. **Real values are never
committed to this repository.** This file is the single place that documents:

1. which credentials exist;
2. where each real value lives (Linux host and/or Windows guest);
3. how each value is injected during deployment;
4. how to rotate it and where to update the copies.

## Inventory

| Credential | Used by | Real value stored at | Injected via |
| --- | --- | --- | --- |
| Windows admin password (`vmadmin`) | local user, SSH password fallback, AutoLogon | host: `secrets/secrets.local.env` → `ADMIN_PASSWORD`; guest: `C:\Admin\config\local-secrets.json` → `adminPassword`; AutoLogon: `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\DefaultPassword` | `build-iso.sh` writes `bootstrap.env` on the bootstrap ISO; `bootstrap.ps1` creates the user; `enable-autologon.ps1` / `set-autologon-permanent.ps1` write the Winlogon key |
| SSH key pair | passwordless `ssh vmadmin@<guest>` | host: `secrets/admin_ed25519` (private) + `secrets/admin_ed25519.pub` (both git-ignored); guest: `C:\ProgramData\ssh\administrators_authorized_keys` (ACL: `S-1-5-32-544:F`, `SYSTEM:F`) | `build-iso.sh` embeds the public key into the bootstrap ISO; `bootstrap.ps1` writes it and fixes the ACL |
| Sunshine Web UI user | `https://<guest>:47990` login | username fixed: `sunshine`; password: guest `C:\Admin\config\local-secrets.json` → `sunshineWebPassword`; hash+salt: `C:\Program Files\Sunshine\config\sunshine_state.json` | `set-sunshine-creds.ps1` reads `-Password` → `$env:SUNSHINE_WEB_PASSWORD` → guest local secrets, then writes the state file and the guest local secrets |
| Moonlight pairing | stream authentication | host: `~/.config/Moonlight Game Streaming Project/Moonlight.conf` (client cert/private key); guest: `sunshine_state.json` → `paired_clients` | first `moonlight pair` flow |
| Windows product key | Setup only, no activation | `Autounattend.xml` (public generic key) | answer file |
| VNC/SPICE | final rescue display | **no password by default**; listen `127.0.0.1` only | libvirt domain XML; add a password only if you also expose it beyond loopback |
| QEMU Guest Agent | out-of-band control | **no authentication**; virtio-serial channel is host-local | libvirt channel `org.qemu.guest_agent.0` |

## Local secret files

Host (`secrets/secrets.local.env`, git-ignored; template: `secrets.local.env.example`):

```bash
ADMIN_PASSWORD=...
SUNSHINE_WEB_PASSWORD=...
SSH_PUB_KEY=secrets/admin_ed25519.pub   # optional, defaults to secrets/
```

Guest (`C:\Admin\config\local-secrets.json`, never part of this repo;
template: `config/local-secrets.example.json`):

```json
{
  "adminPassword": "...",
  "secondNicMac": "AA-BB-CC-DD-EE-FF",
  "sunshineWebPassword": "..."
}
```

The Windows AutoLogon registry key
`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\DefaultPassword`
is a third copy of the admin password. It is required for the interactive
session that Sunshine captures, and it is readable only by local
administrators.

The Sunshine Web UI password is stored as a salted hash
(`sha256(password + salt)`, hex bytes in reverse order) inside
`C:\Program Files\Sunshine\config\sunshine_state.json`. Do not edit that file
by hand; use `set-sunshine-creds.ps1`.

## Verifying the current state (without printing secrets)

On the guest (over SSH or via QGA):

```powershell
C:\Admin\scripts\get-credentials-status.ps1
```

It reports each storage location and whether the value is set. It never
prints the values themselves.

## Rotation

### Windows admin password

```powershell
# 1. On the guest
net user vmadmin <new-password>

# 2. Update the two guest-side copies
C:\Admin\scripts\set-autologon-permanent.ps1 -UserName vmadmin -Password <new-password>
```

Then update the host copy (`secrets/secrets.local.env` → `ADMIN_PASSWORD`) and the
guest JSON (`C:\Admin\config\local-secrets.json` → `adminPassword`). A reboot
is not required for the password itself, but AutoLogon takes effect at the
next logon.

### SSH key

```bash
# on the host
ssh-keygen -t ed25519 -f secrets/admin_ed25519 -N ''

# replace the guest's authorized key
scp secrets/admin_ed25519.pub win-dev:C:\Admin\admin_ed25519.pub.new
ssh win-dev 'type C:\Admin\admin_ed25519.pub.new > C:\ProgramData\ssh\administrators_authorized_keys'
ssh win-dev 'icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "*S-1-5-32-544:F" /grant "SYSTEM:F"'
ssh win-dev 'Restart-Service sshd'
```

Also update `secrets/admin_ed25519.pub` in the bootstrap directory for future
reinstalls, and remove the old public key from any other machines that used it.

### Sunshine Web UI

```powershell
# on the guest
C:\Admin\scripts\set-sunshine-creds.ps1 -Username sunshine -Password <new-password>
```

The helper writes the new hash to `sunshine_state.json`, updates
`C:\Admin\config\local-secrets.json`, then **reboots by default** so Sunshine
starts while the VDD display is active (a bare `Restart-Service` can fail when
the virtual display is inactive). Use `-NoReboot` if you plan to reboot later.

Afterwards update the host copy:

```bash
# secrets/secrets.local.env
SUNSHINE_WEB_PASSWORD=<new-password>
```

Verify:

```bash
curl -sk -u sunshine:<new-password> -o /dev/null -w '%{http_code}\n' https://192.168.122.50:47990/
# expect 200
```

### Moonlight pairing

Unpair from the Sunshine Web UI (Clients page), then on the host:

```bash
moonlight pair 192.168.122.50
```

Enter the PIN shown by Moonlight in the Sunshine Web UI PIN page. The client
certificate lives on the host under `~/.config/Moonlight Game Streaming
Project/`; the guest stores the paired client in `sunshine_state.json`.

## Policy

- `secrets/` (passwords + SSH keys), `C:\Admin\config\local-secrets.json`
  and `sunshine_state.json` are never committed.
- Use different passwords for the Windows admin account and the Sunshine Web
  UI.
- Rotate credentials before exposing the VM beyond your own host.
- If you reset a credential, update **every** row in the inventory table at
  the same time (host env, guest JSON, AutoLogon key, Sunshine state).
- Do not paste real values into issue trackers, chat logs or screenshots;
  use `get-credentials-status.ps1` for a safe status check.
