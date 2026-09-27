# Hue Dashboard

A collection of interfaces for controlling **Philips Hue lights** — built for wall-mounted tablets, KDE Plasma, and GNOME Shell.

## What's included

| Interface | Description |
|-----------|-------------|
| `index.html` | Full-screen web app for a wall-mounted tablet |
| `kde-plasmoid/` | KDE Plasma 6 system tray widget |
| `gnome-extension/` | GNOME Shell 45+ panel extension |

All three share the same Hue Bridge API integration and work entirely on your local network — no cloud, no account required.

---

## Web app (tablet dashboard)

A single self-contained HTML file. No build step, no dependencies, no server needed — open it directly in a browser.

**Features:**
- **Dashboard** — room overview with per-light status pills
- **Rooms** — full controls per room: on/off toggles, brightness and colour temperature sliders, touch-optimised for wall mounting
- **Switches** — customisable named shortcuts targeting any light or room
- **Status** — local weather (Open-Meteo) and news (Tagesschau)
- **Notes** — text notepad and finger-drawing whiteboard, saved locally

**Setup:**

1. Open `index.html` in Chrome/Chromium on the tablet.
2. The setup wizard asks for the bridge IP (browsers cannot use the Hue cloud discovery because of CORS; find the IP in your router or the Hue app), checks that a bridge answers there, then waits up to 60 seconds for you to press the bridge button.
3. Credentials are saved in the browser's localStorage. Use the gear icon in the header to reset.

The bridge is only reachable in the home network. When it does not answer, the app shows a notice instead of stale switches and retries every 15 seconds. Polling pauses while the page is hidden. If the browser cannot determine the location, the Status panel asks for a city for the weather.

**Compatibility:** tested on old Android tablets running Chrome 80+. No optional chaining or modern CSS that would break on older browsers.

---

## KDE Plasma widget

A system tray popup with room cards, per-light toggles, brightness sliders, and an "All Off" button.

**Requirements:** KDE Plasma 6

**Install:**
```bash
kpackagetool6 -t Plasma/Applet -i kde-plasmoid
# or to update an existing install:
# kpackagetool6 -t Plasma/Applet -u kde-plasmoid && systemctl --user restart plasma-plasmashell
```
Then right-click the panel → *Add Widgets* → search "Hue Dashboard".

On first launch, the widget walks you through bridge discovery and pairing. Bridge IP and API key are stored in the widget configuration; right-click → *Configure…* to change the IP or forget the pairing.

The bridge is only reachable in the home network. Elsewhere the widget dims its icon, sets itself passive (hidden in the overflow when placed in the system tray) and only checks every two minutes whether it is back home. While the popup is open it refreshes every two seconds.

---

## GNOME Shell extension

A panel indicator with the same controls using native GNOME popup menu components.

**Requirements:** GNOME Shell 45+

**Install:**
```bash
cp -r gnome-extension ~/.local/share/gnome-shell/extensions/hue-dashboard@jo-tud
gnome-extensions enable hue-dashboard@jo-tud
```

On first launch, the extension walks you through bridge discovery and pairing. Credentials are stored in `~/.config/hue-dashboard.json` and persist across restarts. Use "Reset Configuration" in the menu to re-pair.

---

## Getting your Hue API credentials

1. Find your bridge on the network:
   ```
   curl https://discovery.meethue.com
   ```
2. Press the **physical button** on the bridge, then within 30 seconds:
   ```
   curl -X POST http://<bridge-ip>/api -H "Content-Type: application/json" -d '{"devicetype":"hue-dashboard#user"}'
   ```
3. Copy the `username` from the response — that's your API key.

---

## Development

For local development, copy `.env.example` to `.env` and fill in your bridge credentials:

```bash
cp .env.example .env
# edit .env with your bridge IP and API key
```

The `.env` file is git-ignored and will never be checked in.

---

## License

MIT
