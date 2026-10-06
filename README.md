# new_dumb_iPhone

Turns an old iPhone (iPhone 4S, iOS 9.3.5/9.3.6) into a quiet phone, Light Phone style.
One USB cable, Linux. Two levels:

| Level | What you get | How |
|---|---|---|
| **LightHome** (jailbreak) | Black screen, big clock, date, a text list: Phone, Messages, Camera, Directions, Music, Podcasts, Tools (Photos, Alarm, Calendar, Notes, Voice memo, Calculator, Web, Settings) | `./deploy.sh` |
| **Dumb profile** (no jailbreak) | Normal iOS icons, but only the Light Phone set; everything else hidden | `./install.sh` |

## Quick start

```
git clone <this repo> && cd new_dumb_iPhone
./dumbify.sh
```

Plug the iPhone in (iOS 9.3.5 or 9.3.6, 32-bit: iPhone 4S/5/5c) and follow the prompts.
The script does everything from the computer except two steps that have to happen on the phone,
and it waits for each one:

1. **Jailbreak:** Safari, `http://carbon.sep.lol`, tap Run. Cydia appears.
2. **OpenSSH:** in Cydia, search OpenSSH and install it.
   The first time, the script then asks once for the phone's root password (`alpine`),
   installs a key, and **turns off password logins** on the phone.

After that it installs, by itself: the iocaste untether (jailbreak survives reboots),
Cydia Substrate, and LightHome. On the first run it also downloads the iOS build tools into `tools/` (~300 MB).

No working Home button? Press **volume-down twice quickly**.

Edit the lists at the top of [`lighthome/Tweak.x`](lighthome/Tweak.x) and run `./deploy.sh` to update.
`./deploy.sh --remove` puts the normal home screen back.

## WhatsApp (optional, needs a computer at home)

WhatsApp no longer runs on iOS 9, and WhatsApp Web refuses iOS 9 Safari. `whatsapp.sh` runs a small
bridge on your computer instead ([`wabridge/`](wabridge), Go, built on
[whatsmeow](https://github.com/tulir/whatsmeow)). It links to your WhatsApp as a companion device,
like WhatsApp Web, and serves a plain black chat page that LightHome opens from a **WhatsApp** row.

```
./whatsapp.sh            # build, link (scan the QR from your main phone), install on the phone
./whatsapp.sh --remove   # stop it, remove it from the phone, delete its data
```

- Chats, unread counts, ticks, search (people, groups, messages), new chat by number,
  and **photos from the camera roll** (take them with Camera, then Photo in a chat).
- Works on your **home Wi-Fi while the computer is on** (it runs as a user service and starts with it).
- Needs WhatsApp on another phone (it links as a companion device). Text and photos out;
  incoming media shows as `[photo]`, `[voice message]`... No notifications.
- **Unofficial client**: against WhatsApp's terms. Ban risk is low for personal use, not zero.

Why photos come from the camera roll and not Safari's upload button: on jailbroken iOS 9 the
iCloud Drive extension behind Safari's picker crashes (`invalid sandbox or container: error 45`),
which takes the whole picker down.

**Security of the bridge**
- Session, messages, keys and token live in `~/.local/share/dumb-iphone-whatsapp` (mode 700), never in the repo.
- HTTPS with a private CA made on your computer and installed on the phone; a random token
  (from the LightHome row, then an HttpOnly cookie); CSRF check on every send; requests from
  non-private addresses are refused; the firewall port is opened for your home subnet only.
- To read photos it uses its **own SSH key**, which the phone only accepts for
  [`phone/dumbiphone-gallery`](wabridge/phone/dumbiphone-gallery): list camera-roll photos or read one.
  No shell, no other files, no port forwarding.
- The log has paths and status codes only: no message text, numbers or the token.

## Dumb profile (no jailbreak)

```
./install.sh
```

### What you get

| Dock                     | Page 1                                                                                  | Page 2   |
|---|---|---|
| Phone, Messages, Camera  | Maps, Podcasts, Music, Photos, Clock, Calendar, Notes, Voice Memos, Calculator, Safari, **web** | Settings |

Everything else is hidden. The App Store is gone, so nothing new gets in.
**web** opens [FrogFind](http://frogfind.com), a text-only search and page
reader that works on old Safari. The profile also adds two modern root
certificates (Let's Encrypt, Google) so more HTTPS sites load on iOS 9.

### How it works

1. Installs `usbmuxd` and `uv` if missing, then runs `pymobiledevice3` over USB.
2. First run only: **erases the phone** and marks it *supervised*
   (what Apple Configurator does on a Mac). iOS only lets supervised
   phones hide apps and fix the home screen.
3. Pushes `dumb.mobileconfig`, built from `build_profile.py`.

To change the apps, edit the lists at the top of `build_profile.py` and run
`./install.sh` again (no erase the second time). `./install.sh --undo` removes it.

Keep `keys/`: it holds the supervisor identity that lets this computer
update the phone without prompts.

## Compatibility

Tested end to end on an **iPhone 4S, iOS 9.3.5, from Fedora 44 (x86_64)**. Everything else below is what
the scripts are built for but has not been run on real hardware.

| | `dumbify.sh` (LightHome, jailbreak) | `install.sh` (profile, no jailbreak) |
|---|---|---|
| Devices | 32-bit only: iPhone 4S, 5, 5c; iPad 2-4, iPad mini 1; iPod touch 5 | Any iPhone |
| iOS | 8.2 - 9.3.6 (Carbon covers 8.0 - 9.3.6; LightHome needs 8.2+). Untether added only on 9.3.5/9.3.6 | 9.3 and newer (app hiding and home layout need supervision, iOS 9.3+) |
| Not supported | iPhone 5/5c on iOS 10 (different jailbreak), every 64-bit iPhone (5s and later) | iOS below 9.3 |

Computer: Linux on x86_64 or arm64 with `dnf`, `apt` or `pacman`. Not macOS or Windows.

## Security notes

- `deploy.sh` turns **off password logins** on the phone's SSH right after installing this
  computer's key, so the default `alpine` password can't be used over Wi-Fi.
  The private key is in `keys/`, git-ignored; keep it, it's how you update the phone later.
- `keys/supervisor.pem` (from `install.sh`) can manage a supervised phone. It's git-ignored and `chmod 600`.
- Everything downloaded is pinned: Theos and SDK commits, toolchain, Substrate and untether `.deb`s
  are checked against SHA-256 hashes in `deploy.sh`.
- SHA-1 is allowed **only** for this script's own SSH sessions to the phone (iOS 9's OpenSSH 6.7 needs it),
  and the Fedora/RHEL policy override applies just to that process.
- Jailbreaking turns off iOS code signing protections, and iOS 9 no longer gets security updates.
  Treat the phone as an appliance: no banking, no passwords that matter.

## Limits of a 2011 phone

- **WhatsApp** and **Google Maps** don't run on iOS 9 any more. They're in
  the layout in case you use a newer iPhone (the script works the same there).
- **iMessage, Apple Maps, Podcasts** are the iOS 9 built-ins; they depend on
  Apple still serving iOS 9. Test them after setup.
- Grayscale can't be set by profile: Settings > General > Accessibility >
  Display Accommodations > Grayscale.
