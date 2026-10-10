pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../../"

// One niri event-stream shared by every bar, dock and keyboard face.
// The stream starts with the full state and then sends deltas, so nothing is polled.
Item {
    id: root

    readonly property bool isNiri: SystemInfo.desktopEnv.toLowerCase().indexOf("niri") !== -1

    // Zero-based idx of the focused workspace, and idx -> true for workspaces with windows.
    property int activeIndex: 0
    property var occupiedMap: ({})

    property var keyboardLayouts: []
    property int keyboardLayoutIndex: 0
    property bool keyboardReady: false
    readonly property string keyboardLayout: keyboardLayouts[keyboardLayoutIndex] || ""

    property int subscribers: 0

    function subscribe() {
        subscribers++;
        _syncStream();
    }

    function unsubscribe() {
        subscribers = Math.max(0, subscribers - 1);
        _syncStream();
    }

    function _syncStream() {
        let want = isNiri && subscribers > 0;
        if (eventStream.running !== want) eventStream.running = want;
    }

    // id -> workspace / window objects as niri reports them.
    property var _workspaces: ({})
    property var _windows: ({})

    function _byId(list) {
        let map = {};
        for (let i = 0; i < list.length; i++) map[list[i].id] = list[i];
        return map;
    }

    function _recompute() {
        let withWindows = {};
        for (let id in _windows) {
            let wsId = _windows[id].workspace_id;
            if (wsId !== undefined && wsId !== null) withWindows[wsId] = true;
        }

        let occ = {};
        let focusedIdx = -1;
        let activeIdx = -1;
        for (let id in _workspaces) {
            let w = _workspaces[id];
            let idx = (w.idx !== undefined ? w.idx : w.id) - 1;
            if (w.is_focused) focusedIdx = idx;
            else if (w.is_active && activeIdx < 0) activeIdx = idx;
            if (withWindows[w.id] || (w.active_window_id !== undefined && w.active_window_id !== null)) {
                occ[idx] = true;
            }
        }

        let next = focusedIdx >= 0 ? focusedIdx : (activeIdx >= 0 ? activeIdx : 0);
        if (activeIndex !== next) activeIndex = next;
        if (JSON.stringify(occ) !== JSON.stringify(occupiedMap)) occupiedMap = occ;
    }

    function _handle(ev) {
        let p;
        if ((p = ev.WorkspacesChanged)) {
            _workspaces = _byId(p.workspaces || []);
        } else if ((p = ev.WorkspaceActivated)) {
            let target = _workspaces[p.id];
            if (!target) return;
            for (let id in _workspaces) {
                let w = _workspaces[id];
                if (w.output === target.output) w.is_active = (w.id === p.id);
                if (p.focused) w.is_focused = (w.id === p.id);
            }
        } else if ((p = ev.WorkspaceActiveWindowChanged)) {
            let w = _workspaces[p.workspace_id];
            if (!w) return;
            w.active_window_id = p.active_window_id;
        } else if ((p = ev.WindowsChanged)) {
            _windows = _byId(p.windows || []);
        } else if ((p = ev.WindowOpenedOrChanged)) {
            _windows[p.window.id] = p.window;
        } else if ((p = ev.WindowClosed)) {
            delete _windows[p.id];
        } else if ((p = ev.KeyboardLayoutsChanged)) {
            let kl = p.keyboard_layouts || {};
            keyboardLayouts = kl.names || [];
            keyboardLayoutIndex = kl.current_idx || 0;
            keyboardReady = true;
            return;
        } else if ((p = ev.KeyboardLayoutSwitched)) {
            keyboardLayoutIndex = p.idx || 0;
            return;
        } else {
            return;
        }
        // A burst of events (e.g. the initial state) is applied once.
        Qt.callLater(_recompute);
    }

    Process {
        id: eventStream
        running: false
        command: ["niri", "msg", "--json", "event-stream"]
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                if (data.length === 0) return;
                try {
                    root._handle(JSON.parse(data));
                } catch (e) {}
            }
        }
        onExited: {
            if (root.isNiri && root.subscribers > 0) restartTimer.restart();
        }
    }

    Timer {
        id: restartTimer
        interval: 1000
        repeat: false
        onTriggered: {
            if (root.isNiri && root.subscribers > 0) {
                eventStream.running = false;
                eventStream.running = true;
            }
        }
    }
}
