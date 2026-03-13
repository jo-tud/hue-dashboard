import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import Soup from 'gi://Soup?version=3';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

const POLL_MS    = 2000;
const CONFIG_PATH = GLib.build_filenamev([GLib.get_user_config_dir(), 'hue-dashboard.json']);

// ── Config persistence ───────────────────────────────────────────────────────

function loadConfig() {
    try {
        const [ok, contents] = GLib.file_get_contents(CONFIG_PATH);
        return JSON.parse(new TextDecoder().decode(contents));
    } catch (_) {
        return null;
    }
}

function saveConfig(bridgeIp, apiKey) {
    const data = JSON.stringify({bridgeIp, apiKey});
    GLib.file_set_contents(CONFIG_PATH, data);
}

function deleteConfig() {
    try {
        GLib.unlink(CONFIG_PATH);
    } catch (_) {}
}

// ── Indicator ────────────────────────────────────────────────────────────────

const HueCtrlIndicator = GObject.registerClass(
class HueCtrlIndicator extends PanelMenu.Button {
    _init() {
        super._init(0.0, 'Hue Dashboard', false);

        this._rooms       = {};
        this._lights      = {};
        this._interacting = false;
        this._pollLocked  = false;
        this._pollLockId  = null;
        this._session     = new Soup.Session();
        this._pollTimer   = null;
        this._bridgeIp    = null;
        this._apiUser     = null;

        // Panel icon
        this.add_child(new St.Icon({
            icon_name: 'user-home-symbolic',
            style_class: 'system-status-icon',
        }));

        const config = loadConfig();
        if (config && config.bridgeIp && config.apiKey) {
            this._bridgeIp = config.bridgeIp;
            this._apiUser  = config.apiKey;
            this._buildMenuSkeleton();
            this._startPolling();
        } else {
            this._buildSetupMenu();
        }
    }

    // ── API helpers (use instance bridge/user) ─────────────────────────────────

    _apiBase() {
        return `http://${this._bridgeIp}/api/${this._apiUser}`;
    }

    _apiGet(path, cb) {
        const msg = Soup.Message.new('GET', this._apiBase() + path);
        this._session.send_and_read_async(msg, GLib.PRIORITY_DEFAULT, null, (session, result) => {
            try {
                const bytes = session.send_and_read_finish(result);
                cb(JSON.parse(new TextDecoder().decode(bytes.get_data())));
            } catch (_) {}
        });
    }

    _apiPut(path, body) {
        const msg = Soup.Message.new('PUT', this._apiBase() + path);
        msg.set_request_body_from_bytes(
            'application/json',
            new GLib.Bytes(new TextEncoder().encode(body))
        );
        this._session.send_and_read_async(msg, GLib.PRIORITY_DEFAULT, null, (session, result) => {
            try { session.send_and_read_finish(result); } catch (_) {}
        });
    }

    _lockPoll() {
        this._pollLocked = true;
        if (this._pollLockId) GLib.source_remove(this._pollLockId);
        this._pollLockId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 3000, () => {
            this._pollLocked = false;
            this._pollLockId = null;
            return GLib.SOURCE_REMOVE;
        });
    }

    _fetchState() {
        if (this._pollLocked) return;
        this._apiGet('/lights', data => {
            this._lights = data;
            this._rebuildRooms();
        });
        this._apiGet('/groups', data => {
            this._rooms = data;
        });
    }

    _startPolling() {
        this._fetchState();
        this._pollTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, POLL_MS, () => {
            this._fetchState();
            return GLib.SOURCE_CONTINUE;
        });
    }

    _stopPolling() {
        if (this._pollTimer !== null) {
            GLib.source_remove(this._pollTimer);
            this._pollTimer = null;
        }
    }

    // ── Setup flow ─────────────────────────────────────────────────────────────

    _buildSetupMenu() {
        this.menu.removeAll();

        // Header
        const header = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        const title = new St.Label({
            text: 'HUE // CTRL',
            style: 'font-weight: bold;',
            x_expand: true,
        });
        const setupTag = new St.Label({
            text: 'Setup',
            style: 'color: #888888;',
        });
        header.add_child(title);
        header.add_child(setupTag);
        this.menu.addMenuItem(header);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Setup content section (replaced at each step)
        this._setupSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._setupSection);

        this._showDiscoverStep();
    }

    _showDiscoverStep() {
        this._setupSection.removeAll();

        // Status label
        const searchItem = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        this._discoverLabel = new St.Label({
            text: 'Searching for Hue Bridge...',
            x_expand: true,
        });
        searchItem.add_child(this._discoverLabel);
        this._setupSection.addMenuItem(searchItem);

        // IP entry row
        const entryItem = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        const entryLabel = new St.Label({
            text: 'Bridge IP: ',
            y_align: 2, // Clutter.ActorAlign.CENTER
        });
        this._ipEntry = new St.Entry({
            hint_text: '192.168.x.x',
            can_focus: true,
            x_expand: true,
            style: 'min-width: 160px;',
        });
        entryItem.add_child(entryLabel);
        entryItem.add_child(this._ipEntry);
        this._setupSection.addMenuItem(entryItem);

        // Next button
        const nextItem = new PopupMenu.PopupMenuItem('Next');
        nextItem.label.set_style('font-weight: bold; color: #a8cc8c;');
        nextItem.connect('activate', () => {
            const ip = this._ipEntry.get_text().trim();
            if (ip.length > 0) {
                this._bridgeIp = ip;
                this._showPairStep();
            }
        });
        this._setupSection.addMenuItem(nextItem);

        // Try auto-discovery
        this._discoverBridge();
    }

    _discoverBridge() {
        const msg = Soup.Message.new('GET', 'https://discovery.meethue.com');
        this._session.send_and_read_async(msg, GLib.PRIORITY_DEFAULT, null, (session, result) => {
            try {
                const bytes = session.send_and_read_finish(result);
                const data = JSON.parse(new TextDecoder().decode(bytes.get_data()));
                if (Array.isArray(data) && data.length > 0 && data[0].internalipaddress) {
                    const ip = data[0].internalipaddress;
                    this._discoverLabel.set_text(`Found bridge: ${ip}`);
                    this._ipEntry.set_text(ip);
                } else {
                    this._discoverLabel.set_text('No bridge found — enter IP manually');
                }
            } catch (_) {
                this._discoverLabel.set_text('Discovery failed — enter IP manually');
            }
        });
    }

    _showPairStep() {
        this._setupSection.removeAll();

        // Instructions
        const instrItem = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        const instrLabel = new St.Label({
            text: 'Press the button on your Hue Bridge,\nthen click Connect.',
            x_expand: true,
        });
        instrItem.add_child(instrLabel);
        this._setupSection.addMenuItem(instrItem);

        // Status feedback
        const statusItem = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        this._pairStatusLabel = new St.Label({
            text: `Bridge: ${this._bridgeIp}`,
            style: 'color: #888888;',
            x_expand: true,
        });
        statusItem.add_child(this._pairStatusLabel);
        this._setupSection.addMenuItem(statusItem);

        // Connect button
        const connectItem = new PopupMenu.PopupMenuItem('Connect');
        connectItem.label.set_style('font-weight: bold; color: #a8cc8c;');
        connectItem.connect('activate', () => {
            this._pairStatusLabel.set_text('Connecting...');
            this._pairStatusLabel.set_style('color: #888888;');
            this._attemptPairing();
        });
        this._setupSection.addMenuItem(connectItem);

        this._setupSection.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Back button
        const backItem = new PopupMenu.PopupMenuItem('Back');
        backItem.label.set_style('color: #888888;');
        backItem.connect('activate', () => {
            this._showDiscoverStep();
        });
        this._setupSection.addMenuItem(backItem);
    }

    _attemptPairing() {
        const url = `http://${this._bridgeIp}/api`;
        const body = JSON.stringify({devicetype: 'hue-dashboard#gnome'});
        const msg = Soup.Message.new('POST', url);
        msg.set_request_body_from_bytes(
            'application/json',
            new GLib.Bytes(new TextEncoder().encode(body))
        );
        this._session.send_and_read_async(msg, GLib.PRIORITY_DEFAULT, null, (session, result) => {
            try {
                const bytes = session.send_and_read_finish(result);
                const data = JSON.parse(new TextDecoder().decode(bytes.get_data()));

                if (Array.isArray(data) && data.length > 0) {
                    const entry = data[0];
                    if (entry.error) {
                        if (entry.error.type === 101) {
                            this._pairStatusLabel.set_text('Button not pressed — try again');
                            this._pairStatusLabel.set_style('color: #e06c75;');
                        } else {
                            this._pairStatusLabel.set_text(`Error: ${entry.error.description}`);
                            this._pairStatusLabel.set_style('color: #e06c75;');
                        }
                    } else if (entry.success && entry.success.username) {
                        this._apiUser = entry.success.username;
                        saveConfig(this._bridgeIp, this._apiUser);
                        this._switchToNormalView();
                    }
                }
            } catch (_) {
                this._pairStatusLabel.set_text('Connection failed — check IP');
                this._pairStatusLabel.set_style('color: #e06c75;');
            }
        });
    }

    _switchToNormalView() {
        this.menu.removeAll();
        this._buildMenuSkeleton();
        this._startPolling();
    }

    // ── Menu skeleton (static parts built once) ───────────────────────────────

    _buildMenuSkeleton() {
        // Header row
        const header = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
        const title = new St.Label({
            text: 'HUE // CTRL',
            style: 'font-weight: bold;',
            x_expand: true,
        });
        this._statusLabel = new St.Label({
            text: '…',
            style: 'color: #888888;',
        });
        header.add_child(title);
        header.add_child(this._statusLabel);
        this.menu.addMenuItem(header);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Dynamic room section
        this._roomSection = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._roomSection);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // All Off
        const abk = new PopupMenu.PopupMenuItem('All Off');
        abk.label.set_style('font-weight: bold; color: #e06c75;');
        abk.connect('activate', () => {
            Object.values(this._lights).forEach(l => {
                if (l && l.state) l.state.on = false;
            });
            this._lockPoll();
            this._rebuildRooms();
            Object.keys(this._rooms).forEach(gid => {
                if (this._rooms[gid].type === 'Room')
                    this._apiPut(`/groups/${gid}/action`, JSON.stringify({on: false}));
            });
        });
        this.menu.addMenuItem(abk);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Reset — deletes config and returns to setup
        const resetItem = new PopupMenu.PopupMenuItem('Reset Configuration');
        resetItem.label.set_style('color: #888888;');
        resetItem.connect('activate', () => {
            this._stopPolling();
            this._bridgeIp = null;
            this._apiUser  = null;
            this._rooms    = {};
            this._lights   = {};
            deleteConfig();
            this.menu.removeAll();
            this._buildSetupMenu();
        });
        this.menu.addMenuItem(resetItem);
    }

    // ── Dynamic room/light content ────────────────────────────────────────────

    _rebuildRooms() {
        if (this._interacting) return;

        // Count
        let on = 0, total = 0;
        Object.values(this._lights).forEach(l => {
            if (!l.state) return;
            total++;
            if (l.state.on) on++;
        });

        // Update status label
        this._statusLabel.set_text(`${on}/${total} on`);
        this._statusLabel.set_style(on > 0 ? 'color: #a8cc8c;' : 'color: #888888;');

        // Rebuild room section
        this._roomSection.removeAll();

        const roomIds = Object.keys(this._rooms).filter(gid => this._rooms[gid].type === 'Room');

        roomIds.forEach((gid, roomIdx) => {
            const g = this._rooms[gid];
            const lightIds = g.lights || [];
            const anyOn = lightIds.some(lid => this._lights[lid]?.state?.on);

            // Room toggle
            const roomItem = new PopupMenu.PopupSwitchMenuItem(g.name, anyOn);
            roomItem.label.set_style('font-weight: bold;');
            roomItem.connect('toggled', (_item, newState) => {
                lightIds.forEach(lid => {
                    if (this._lights[lid] && this._lights[lid].state)
                        this._lights[lid].state.on = newState;
                });
                this._lockPoll();
                this._rebuildRooms();
                this._apiPut(`/groups/${gid}/action`, JSON.stringify({on: newState}));
            });
            this._roomSection.addMenuItem(roomItem);

            // Individual lights
            lightIds.forEach(lid => {
                const l = this._lights[lid];
                if (!l) return;
                const st = l.state || {};

                // Light switch
                const lightItem = new PopupMenu.PopupSwitchMenuItem(`  ${l.name}`, !!st.on);
                lightItem.label.set_style('font-size: 0.9em;');
                lightItem.connect('toggled', (_item, newState) => {
                    if (l.state) l.state.on = newState;
                    this._lockPoll();
                    this._rebuildRooms();
                    this._apiPut(`/lights/${lid}/state`, JSON.stringify({on: newState}));
                });
                this._roomSection.addMenuItem(lightItem);

                // Brightness slider (only when light is on and dimmable)
                if (st.on && st.bri !== undefined) {
                    const slider = new PopupMenu.PopupSliderMenuItem(st.bri / 254);
                    slider.connect('drag-begin', () => {
                        this._interacting = true;
                    });
                    slider.connect('drag-end', () => {
                        this._interacting = false;
                        const bri = Math.max(1, Math.round(slider.value * 254));
                        this._apiPut(`/lights/${lid}/state`, JSON.stringify({bri}));
                    });
                    this._roomSection.addMenuItem(slider);
                }
            });

            // Separator between rooms (not after the last one)
            if (roomIdx < roomIds.length - 1)
                this._roomSection.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        });
    }

    // ── Cleanup ───────────────────────────────────────────────────────────────

    destroy() {
        this._stopPolling();
        if (this._pollLockId) {
            GLib.source_remove(this._pollLockId);
            this._pollLockId = null;
        }
        super.destroy();
    }
});

// ── Extension lifecycle ───────────────────────────────────────────────────────

export default class HueCtrlExtension extends Extension {
    enable() {
        this._indicator = new HueCtrlIndicator();
        Main.panel.addToStatusArea(this.uuid, this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
