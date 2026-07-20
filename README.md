# Nextcloud over Tor — onion address and nothing more

A self-contained Nextcloud stack that is reachable **only** through a Tor v3
onion address. No clearnet exposure, no TLS certificates, no domain names.
The whole folder is the deployable unit: copy it to a machine with Docker and
run `./setup.sh`.

## How it works

- `db` (MariaDB), `redis`, `app` (Nextcloud), and `cron` live on an
  **internal-only** Docker network — they cannot reach or be reached from the
  internet at all.
- Plain HTTP is used on purpose: a Tor circuit to a v3 onion is already
  end-to-end encrypted and authenticates the server, so TLS would add nothing.
- Two modes, auto-detected by `setup.sh`:

| | standalone (any Linux box) | whonix (Whonix-Workstation) |
|---|---|---|
| Tor | local `tor` container (built from Alpine, so no third-party image ever touches the onion key) | the Whonix-Gateway's Tor — running our own would be Tor-over-Tor |
| Host exposure | **zero** published ports | port 8080 on the Workstation's internal interface, reachable only by the Gateway |
| Onion identity | `tor_keys` Docker volume | `/var/lib/tor/nextcloud/` on the Gateway |

## Deploy: standalone

```sh
./setup.sh
```

That's it. The script generates secrets into `.env`, creates the onion
identity, installs Nextcloud with the onion address trusted, and prints the
URL and admin credentials at the end.

## Deploy: Whonix (KVM / virt-manager)

Inside the **Workstation** (everything it does is automatically torified):

```sh
git clone https://github.com/<you>/nextcloud-onion.git
cd nextcloud-onion
./install.sh
```

`install.sh` installs Docker if it's missing (using the distro packages, or
Docker's official Debian repo on older Whonix releases), adds you to the
`docker` group, and hands off to `setup.sh` — which walks you through the
Gateway step and asks for the resulting onion address, so the whole
deployment is a single command.

### Offline alternative: no cloning inside the VM

If you'd rather not fetch anything from inside the Workstation, copy the
folder in from the host — it's a few KB. Copy it **without `.env`** so the
new machine generates fresh secrets, then run `./install.sh` as above.

**Shared folder (virtiofs):**

1. Host: virt-manager → Whonix-Workstation → shut it down → Add Hardware →
   Filesystem: driver `virtiofs`, source path = this folder, target = `nextcloud`.
   (Enable "Shared memory" under Memory settings if virt-manager asks for it.)
2. Guest:
   ```sh
   sudo mount -t virtiofs nextcloud /mnt
   cp -r /mnt ~/Nextcloud_Onion && sudo umount /mnt
   rm -f ~/Nextcloud_Onion/.env && chmod +x ~/Nextcloud_Onion/setup.sh
   ```

**Alternative — attach an ISO** (no VM config changes that persist):

```sh
# on the host
mkisofs -R -o nextcloud-onion.iso Nextcloud_Onion/
# attach as a CDROM in virt-manager, then in the guest:
sudo mount /dev/cdrom /media/cdrom
cp -r /media/cdrom ~/Nextcloud_Onion && sudo umount /media/cdrom
chmod -R u+w ~/Nextcloud_Onion && rm -f ~/Nextcloud_Onion/.env
```

### What to expect during the run

- Pulling ~1.5 GB of images over Tor is slow and can hit Docker Hub rate
  limits (`429 toomanyrequests`). If that happens, re-run `./install.sh`
  later or get a new Tor circuit first (on the Gateway:
  `sudo systemctl restart tor@default`).
- The script prints the exact Gateway steps: append two torrc lines to
  `/usr/local/etc/torrc.d/50_user.conf` on the **Gateway** (open its console
  in virt-manager), reload Tor, and read the generated hostname there.
- Paste that hostname back into the waiting prompt — or finish any time
  later with `./setup.sh --onion youraddress...xyz.onion`. The recommended
  apps (below) install during this final step.

## Connecting as a client

- **Tor Browser**: just open `http://<address>.onion`.
- **Android/iOS apps**: run Orbot in VPN mode, then use the onion URL in the
  Nextcloud app.
- **Desktop sync client**: run a local Tor, then in the client settings set a
  SOCKS5 proxy `127.0.0.1:9050` and use the onion URL.

## Operating it

```sh
docker compose --profile standalone-tor ps        # status (standalone)
docker compose --profile standalone-tor logs -f   # logs
docker compose --profile standalone-tor down      # stop (data persists)
docker compose exec -u www-data app php occ ...   # any occ command
```

On Whonix use `docker compose -f docker-compose.yml -f docker-compose.whonix.yml ...` instead.

## Back up these or lose everything

- **The onion identity** — losing it means losing your address forever:
  - standalone: `docker run --rm -v nextcloud-onion_tor_keys:/keys alpine tar cz -C /keys . > tor_keys.tar.gz`
  - whonix: `/var/lib/tor/nextcloud/` on the **Gateway**
- **`.env`** — all passwords (git-ignored; keep it out of any repo).
- **User data**: the `nextcloud-onion_nextcloud_data` and `nextcloud-onion_db_data` volumes.

## Notes

- **Apps**: `setup.sh` installs the recommended suite automatically — Calendar,
  Contacts, Mail, Notes, Tasks, Talk (chat), and Nextcloud Office with the
  built-in CODE server (office editing served through the same onion URL, no
  extra container). Not included, on purpose (poor fit for Tor or extra
  attack surface): Talk audio/video calls (WebRTC won't traverse Tor),
  Whiteboard (needs its own backend), Imaginary, full-text search, ClamAV.
- In standalone mode the app container normally has no internet route
  (`has_internet_connection=false`); the script attaches it to the external
  network only while installing apps, then detaches it again. To add more
  apps later, re-use that trick or `occ app:install` on Whonix where the
  store just works (torified by the Gateway).
- The onion address itself is the first access barrier (unguessable, never
  published anywhere unless you share it). Nextcloud's own login + optional
  2FA is the second. If you later want connections to be impossible without a
  client key, Tor client authorization can be added on top.
- Nextcloud major version is pinned via `NEXTCLOUD_IMAGE` in `.env`.

## License

MIT — see [LICENSE](LICENSE).
