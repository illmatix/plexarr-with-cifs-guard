# Media Stack (Plex/Sonarr/Radarr) — Host Mount + Docker Startup Guide

This README explains how to ensure your NAS share is mounted **before** Docker starts, so containers bind the **actual network share** and not an empty local directory. It also includes pre/post Docker checks and a debugging checklist.

---

## Overview

- **Goal:** `/mnt/nas` is mounted to your NAS share before Docker/Compose starts (no races).
- **Mount type:** CIFS/SMB (adjust to NFS if you use that).
- **Key idea:** Use a **static mount** in `/etc/fstab` and make Docker **require** it via `RequiresMountsFor=/mnt/nas`.

---

## Host OS Setup

### 1) Create the mountpoint
```bash
sudo mkdir -p /mnt/nas
```

### 2) Add credentials (recommended)
```bash
sudo install -m 700 -d /etc/samba
sudo bash -c 'cat >/etc/samba/creds-nas <<EOF
username=YOUR_NAS_USER
password=YOUR_NAS_PASS
EOF'
sudo chmod 600 /etc/samba/creds-nas
```

### 3) `/etc/fstab` entry (static, no automount)
Edit `/etc/fstab`:
```fstab
//10.0.0.5/nas  /mnt/nas  cifs  credentials=/etc/samba/creds-nas,vers=3.0,iocharset=utf8,uid=1000,gid=1000,file_mode=0664,dir_mode=0775,_netdev,nofail  0  0
```
**Tips**
- If you see odd caching behavior or wrong file listings, add: `cache=none,noserverino`
- If your NAS supports newer SMB: `vers=3.1.1`
- For NFS, replace the type/options accordingly.

### 4) Activate and verify the mount
```bash
sudo systemctl daemon-reload
sudo systemctl restart remote-fs.target
sudo mount -a

# Verify it's mounted and populated
findmnt /mnt/nas
df -T /mnt/nas
ls -al /mnt/nas | head
ls -al /mnt/nas/TV | head
ls -al /mnt/nas/Movies | head
```
Expected: `df -T` shows `cifs` (or `nfs`), and `ls` shows your content.

---

## Make Docker Wait for the Mount

Create a systemd override for Docker:

```bash
sudo systemctl edit docker.service
```

Paste and save:
```ini
[Unit]
RequiresMountsFor=/mnt/nas
After=remote-fs.target mnt-nas.mount
```

Apply:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now docker.socket
sudo systemctl restart docker
```

> The override file is stored at:
> `/etc/systemd/system/docker.service.d/override.conf`

---

## Pre-Docker Checklist (before `docker compose up -d`)

```bash
# 1) Confirm host mount is correct and populated
findmnt /mnt/nas
ls -al /mnt/nas/TV | head
ls -al /mnt/nas/Movies | head
id  # ensure your UID/GID match PUID/PGID in .env (e.g., 1000:1000)

# 2) Check share permissions (especially with SMB)
ls -ld /mnt/nas /mnt/nas/TV /mnt/nas/Movies

# 3) Verify .env paths match what compose uses
grep -E 'MEDIA_ROOT|CONFIG_ROOT|TRANSCODE_DIR' .env
```

**Path conventions inside containers (from compose):**
- Sonarr: `/tv`, `/downloads`
- Radarr: `/movies`, `/downloads`
- Plex: `/tv`, `/movies`
- qBittorrent: `/downloads` (optional `/TV`, `/Movies`)

**Do not** point Sonarr/Radarr/Plex at host paths like `/mnt/nas/...` inside the apps. Use their container paths (`/tv`, `/movies`, `/downloads`).

---

## Bring Up the Stack

```bash
docker compose up -d

# Sanity-check inside containers (must show real NAS content)
docker exec -it sonarr sh -c 'ls -al /tv | head'
docker exec -it radarr  sh -c 'ls -al /movies | head'
docker exec -it qbittorrent sh -c "ls -al /downloads | head"
docker exec -it plex sh -c 'ls -ald /tv /movies'
```

If those look sparse, verify what Docker actually bound:
```bash
docker inspect sonarr  --format '{{ json .Mounts }}' | jq
docker inspect radarr  --format '{{ json .Mounts }}' | jq
docker inspect plex    --format '{{ json .Mounts }}' | jq
```
Expect `"Source": "/mnt/nas/TV" -> "Destination": "/tv"`, etc.

---

## Debugging Checklist

### Mount status & conflicts
```bash
findmnt -R /mnt/nas
grep -E '/mnt/nas($|/TV|/Movies)' /proc/self/mountinfo
mount | grep -E ' /mnt/nas($|/TV|/Movies) '
df -T /mnt/nas /mnt/nas/TV /mnt/nas/Movies
```
- If `/mnt/nas/TV` shows a **separate** mount, it may be masking the parent: `sudo umount -l /mnt/nas/TV`

### Clean restart of the mount (with Docker stopped)
```bash
# stop socket activation to prevent auto-restart
sudo systemctl stop docker.socket docker.service

sudo umount -l /mnt/nas 2>/dev/null || true
sudo systemctl daemon-reload
sudo mount -a

# verify
findmnt /mnt/nas
ls -al /mnt/nas/TV | head
```

### CIFS caching quirks
If the view flips between “wrong” and “right”, remount with:
```bash
sudo umount -l /mnt/nas
sudo mount -t cifs //10.0.0.5/nas /mnt/nas \
  -o credentials=/etc/samba/creds-nas,vers=3.0,uid=1000,gid=1000,file_mode=0664,dir_mode=0775,cache=none,noserverino
```
If that fixes it, add `cache=none,noserverino` to `/etc/fstab`.

### Permissions
Ensure PUID/PGID (e.g., 1000:1000) can read/write:
```bash
sudo chown -R 1000:1000 /mnt/nas/TV /mnt/nas/Movies /mnt/nas/downloading  # NFS/local only (not SMB)
sudo chmod -R u+rwX,g+rwX /mnt/nas/TV /mnt/nas/Movies /mnt/nas/downloading
```
> For SMB, prefer fixing permissions/share ACLs on the NAS or mount with `uid=1000,gid=1000,file_mode=0664,dir_mode=0775`.

### App-level paths (common cause)
- **Sonarr** → Settings → Media Management → Root Folders: **/tv**
  Completed Download Handling: **/downloads**
  Use **Mass Editor → Change Root Folder** if needed.
- **Radarr** → Root Folders: **/movies**; Completed: **/downloads**
- **Plex** → Library Folders: **/tv**, **/movies**

---

## Maintenance Tips

- During maintenance, prevent socket auto-starting Docker:
  ```bash
  sudo systemctl stop docker.socket docker.service
  ```
- After changing fstab or systemd overrides:
  ```bash
  sudo systemctl daemon-reload
  sudo systemctl restart remote-fs.target
  sudo mount -a
  sudo systemctl restart docker
  ```
- Keep `PLEX_CLAIM` only for first link; remove it afterward to avoid re-claiming on restarts.
- Keep path **case** consistent: use `/tv` and `/movies` everywhere (avoid mixing `/TV` vs `/tv`).

---

## Quick “All Good?” Checklist

- `findmnt /mnt/nas` shows `cifs` and correct source (`//10.0.0.5/nas`)
- `ls /mnt/nas/TV` and `ls /mnt/nas/Movies` show expected files
- `systemctl cat docker.service` shows the `RequiresMountsFor=/mnt/nas` override
- `docker exec sonarr ls /tv | head` shows the same content as `ls /mnt/nas/TV | head`
- `docker inspect <svc> | jq .[].Mounts` shows correct `Source`→`Destination` mappings