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
2. The built-in setup wizard will discover your bridge and walk you through pairing — just press the bridge button when prompted.
3. Credentials are saved in the browser's localStorage. Use the gear icon in the header to reset.

**Compatibility:** tested on old Android tablets running Chrome 80+. No optional chaining or modern CSS that would break on older browsers.

---

## KDE Plasma widget

A system tray popup with room cards, per-light toggles, brightness sliders, and an "All Off" button.

**Requirements:** KDE Plasma 6

**Install:**
```bash
cp -r kde-plasmoid ~/.local/share/plasma/plasmoids/io.github.jo-tud.hue-dashboard
# or to update an existing install:
# rm -rf ~/.local/share/plasma/plasmoids/io.github.jo-tud.hue-dashboard && cp -r kde-plasmoid ~/.local/share/plasma/plasmoids/io.github.jo-tud.hue-dashboard
plasmashell --replace &
```
Then right-click the panel → *Add Widgets* → search "Hue Dashboard".

On first launch, the widget walks you through bridge discovery and pairing. Credentials are stored via Qt Settings and persist across restarts.

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
