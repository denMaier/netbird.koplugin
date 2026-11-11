<img src="assets/icon.svg" width="64" height="64" alt="">

# NetBird for KOReader

Joins your e-reader to your [NetBird](https://netbird.io) network from inside
KOReader, so OPDS, progress sync and other KOReader features can reach your
self-hosted services from anywhere. It works with NetBird Cloud and self-hosted
servers. That's all it does.

## Credit

This plugin is adapted from
[koreader-tailscale](https://github.com/victoria-riley-barnett/koreader-tailscale) by
Victoria B., which does the same job for Tailscale. Its structure and menu come from there,
and it is MIT licensed like this one.

## Tested on one device: testers very welcome

So far this has only been tested on one real device: **Kindle Paperwhite 12th gen**, jailbroken, in TUN mode,
reaching a domain resource behind a reverse proxy through NetBird Cloud.

Kobo, PocketBook, other Kindles and userspace mode have not been tried on real hardware. The
automated tests simulate 32-bit ARM without TUN, but a simulation isn't a device.

If you try it on anything else, please
[open an issue](https://github.com/denMaier/netbird.koplugin/issues) with your device, whether
Status says TUN or userspace, and what worked or didn't. Reports that it simply works are
useful too.

## What it downloads

The plugin doesn't include NetBird. When you agree during setup, your device downloads the
official NetBird client from
[NetBird's GitHub releases](https://github.com/netbirdio/netbird/releases): about 15 MB, 40 MB
once unpacked. The version and its SHA-256 hash are pinned in `netbird.sh`, and a mismatch
refuses to install.

The NetBird client has its own license, BSD-3-Clause, and its own copyright, NetBird GmbH &
Authors. This plugin is an independent project, not made or endorsed by NetBird. Likewise, it
isn't made or endorsed by Tailscale.

## Install

Needs a 32-bit or 64-bit ARM device, and about 60 MB of free space while installing
(40 MB after). Updating NetBird needs about 100 MB, because the old version stays until
the new one is ready.

1. Download `netbird.koplugin-<version>.zip` from
   [Releases](https://github.com/denMaier/netbird.koplugin/releases) and unzip it
   into KOReader's plugins directory, so that you get a `netbird.koplugin` folder there:
   - Kindle: `/mnt/us/koreader/plugins/`
   - Kobo: `/mnt/onboard/.adds/koreader/plugins/`
   - PocketBook: `/mnt/ext1/applications/koreader/plugins/`
2. Restart KOReader.
3. Open Network → NetBird VPN → **Set up NetBird**. In reader mode, that's the gear icon
   → Network → NetBird VPN.

**With [ZenPM](https://github.com/xZenLabs/zen-pm):** this plugin is its own ZenPM repository. Add
this as a source, then install NetBird VPN from it:

```
https://raw.githubusercontent.com/denMaier/netbird.koplugin/main
```

ZenPM labels it unsigned, because it is. ZenPM's uninstall only removes the plugin, so use
Advanced → Uninstall NetBird first: that stops NetBird and removes its files and identity.

Setup installs NetBird if you agree, tells you which mode your device runs in, and walks
you through signing in.

## What you set up in NetBird

This depends on your device's mode, which setup tells you.

### TUN mode: reach your server by name

1. In your NetBird dashboard, create a network with a **domain resource** for your server,
   such as `opds.example.com`.
2. Add a routing peer to that network: a NetBird peer that can reach the server.
3. Add a policy that lets this device reach the resource.
4. Enter the resource's name during setup.
5. In KOReader, use the server's usual address, such as `https://opds.example.com/opds`.

KOReader then asks NetBird's DNS for those names only, and keeps the real name for your
reverse proxy and its certificate. Every other name uses the device's normal DNS. If
NetBird can't resolve a listed name while connected, the connection fails rather than
going out over the regular network. With NetBird turned off, those names use the
device's normal DNS again, so at home, where you can reach your server directly, just
turn NetBird off. A redirect to another name needs that name listed too.

If your server is a NetBird peer itself, you can use its NetBird IP instead, as below.

Other kinds of NetBird setup, such as IP resources, peer names or your own DNS zones,
may also work in TUN mode, but they haven't been tested.

### Userspace mode: reach your server by IP

Domain names and domain resources don't work in this mode.

1. Install NetBird on your OPDS server, so that it is a peer itself.
2. Add a policy that lets this device reach it.
3. In KOReader, use the server's NetBird IP, such as `http://100.92.1.5:8080/opds`.

A server behind a reverse proxy that needs its real name won't work this way.

### Signing in

- **Scan QR code:** scan it with your phone, check that your phone shows the same
  code as the e-reader, and approve. This needs an identity provider on the server,
  which NetBird Cloud has.
- **Use a setup key:** type a key from your dashboard's Setup Keys page. You can also put
  it in `<KOReader data dir>/netbird/setup.key` and tap the top row. The key is deleted
  from the device once connected, because it is only needed to register.

If you host NetBird yourself, set the server during setup. Changing it later signs the
device out, because a different server means a new peer.

## Using it

The top row of the menu shows the connection, and tapping it does what it says: connect,
disconnect or sign in. You can also assign it to a gesture ("Toggle NetBird VPN").
KOReader remembers your choice: connected stays connected across restarts, off stays off
with no daemon running. NetBird only runs while KOReader does. Leaving KOReader stops it,
and it comes back the next time you open KOReader.

Check the Status screen if something doesn't work. Every setup step is also available
on its own under Advanced, along with updating and uninstalling.

DNS stays off until you list a name. With it on, NetBird tries to rewrite
`/etc/resolv.conf`. On a Kindle the rootfs is read-only, so that fails harmlessly. Where
it is writable, such as a Kobo, NetBird rewrites the file while connected and restores it
when it stops, or at the next start after a crash.

## TUN and userspace mode

The plugin picks one when NetBird starts.

|                          | TUN                           | Userspace                      |
| ------------------------ | ----------------------------- | ------------------------------ |
| When                     | `/dev/net/tun` is usable      | Otherwise, or if forced        |
| KOReader to peers        | Yes                           | Yes, through a SOCKS5 proxy    |
| Other programs to peers  | Yes                           | Only if they speak SOCKS5      |
| Peers to the device      | Yes, if your policies allow   | No                             |

TUN mode needs a working TUN driver and root, which KOReader usually has on a
jailbroken device. Many jailbroken Kindles have no TUN driver. If NetBird can't create its
TUN interface anyway, it switches to userspace mode by itself until KOReader restarts. If
TUN is unstable on your device, turn on Advanced → Force userspace mode.

In userspace mode NetBird only offers a SOCKS5 proxy on `127.0.0.1:1080`, and
KOReader can't use SOCKS5. So `netbird_connect.lua` patches LuaSocket's `connect()` to
send connections to `100.64.0.0/10` through that proxy. Everything else, including
regular internet traffic, goes the normal way. While NetBird is on, or if it stops
unexpectedly, those connections fail rather than go out over the regular network. Once
you turn NetBird off, KOReader connects to those addresses the normal way again.

## What it doesn't do

- Domain names in userspace mode, or for programs other than KOReader.
- Exit nodes and picking routes. Manage those on your NetBird dashboard.
- HTTP proxying for other programs.
- Inbound connections in userspace mode, such as SSH or Syncthing to the device.
- Android, or anything that isn't ARM.

## Good to know

- **Memory:** the daemon is a large Go program. It used about 70 MB of RAM when
  idle on 32-bit ARM, which can matter on a device with 256 MB. Turning NetBird off
  frees it all.
- **Updates:** the NetBird version is pinned in `netbird.sh` with its SHA-256 hash,
  and a mismatch refuses to install. A new NetBird version arrives with a new plugin
  version. After updating the plugin, tap Install/Update NetBird. Your device
  identity is kept.
- **Credentials:** the device's WireGuard private key is in
  `<KOReader data dir>/netbird/state/`. That is usually a FAT partition with no file
  permissions, readable by anyone who can mount the e-reader over USB. If you lose the
  device, delete the peer from your dashboard.
- **USB storage mode** stops NetBird first and brings it back afterwards. So does
  leaving KOReader for the stock reader.
- **Uninstalling** from Advanced asks first, then removes the binary and the identity,
  not the peer on your dashboard.

## Files

```
main.lua             menu, state and decisions
netbird.sh           install, start, stop; no decisions of its own
netbird_connect.lua  gets KOReader to peers: SOCKS5 in userspace mode, listed hostnames
netbird_qr.lua       sign-in screen with the QR code and the code to compare
```

On the device, `<KOReader data dir>/netbird/` holds the binary, state and
`netbird.log`, and `/tmp/netbird-koreader/` holds the socket and sign-in output.

## Test

```sh
test/run.sh
```

Needs Docker on an arm64 machine. CI runs it on every pull request on GitHub's arm64 runners. It starts a real NetBird server and a real peer,
then runs the real plugin and binary with stubbed KOReader widgets on two simulated
e-readers: arm64 with TUN on a FAT data dir, and 32-bit ARM without TUN. Each runs
through installing, tampered downloads, bad keys, connecting, HTTP and HTTPS to the
peer, reboots, USB storage mode, sign-in and uninstalling.

It doesn't cover real e-reader kernels or KOReader's actual UI. For the UI, see below.

### In the KOReader emulator

```sh
test/emulator/run.sh /path/to/koreader-dev
```

Runs the plugin inside KOReader's real desktop emulator at a Kobo Clara's size, with a
stand-in for the NetBird binary, since the emulator runs on x86. It goes through setup,
signing in with a QR code and with a key, a sign-in carried from the file browser into a
book, falling back from a broken TUN device, the menus, uninstalling, a restart and
quitting, and saves a screenshot of each screen. It needs an extracted KOReader AppImage, Xvfb and
`proot`; see the script for the layout it expects. It doesn't test NetBird itself, which
`test/run.sh` does. CI runs it too and keeps the screenshots as a build artifact.

## License

The plugin is MIT licensed, like the plugin it is based on. See [LICENSE](LICENSE). The
NetBird client it downloads is licensed separately, as described under
[What it downloads](#what-it-downloads).
