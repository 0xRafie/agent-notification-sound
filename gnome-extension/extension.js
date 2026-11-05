// Tints the notification banners that notify.sh and omp/index.ts send on Linux.
// They carry the class in the "x-agent-notify-class" hint; GNOME drops unknown
// hints, so NotifyAsync is wrapped to read it and tag the notification, and the
// banner gets an "agent-notify-<class>" style class when it is shown. Other
// notifications are left alone.
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const HINT = 'x-agent-notify-class';
const CLASSES = new Set(['done', 'progress', 'question', 'failed', 'quiet']);

function readClass(hints) {
    try {
        const cls = hints?.[HINT]?.deepUnpack();
        return CLASSES.has(cls) ? cls : null;
    } catch {
        return null;
    }
}

export default class AgentNotifyColors extends Extension {
    enable() {
        const daemon = Main.notificationDaemon?._fdoNotificationDaemon;
        const tray = Main.messageTray;
        if (!daemon?.NotifyAsync || !tray?._showNotification)
            return;
        this._daemon = daemon;
        this._tray = tray;

        // D-Bus calls look NotifyAsync up on the object each time, so an own
        // property shadows the class method until disable() deletes it.
        const notify = Object.getPrototypeOf(daemon).NotifyAsync;
        daemon.NotifyAsync = function (params, invocation) {
            const cls = readClass(params[6]);
            if (!cls)
                return notify.call(this, params, invocation);
            // The banner can be shown before NotifyAsync returns, so tag the
            // notification as soon as it exists: an updated one is already in
            // the map, a new one is tagged when it is added.
            const replacesId = params[1];
            const existing = replacesId !== 0 ? this._notifications.get(replacesId) : null;
            if (existing)
                existing._agentNotifyClass = cls;
            const map = this._notifications;
            map.set = function (id, notification) {
                notification._agentNotifyClass = cls;
                return Map.prototype.set.call(this, id, notification);
            };
            try {
                return notify.call(this, params, invocation);
            } finally {
                delete map.set;
            }
        };

        const show = Object.getPrototypeOf(tray)._showNotification;
        tray._showNotification = function (...args) {
            const result = show.apply(this, args);
            const cls = this._notification?._agentNotifyClass;
            if (cls)
                this._banner?.add_style_class_name(`agent-notify-${cls}`);
            return result;
        };
    }

    disable() {
        if (this._daemon)
            delete this._daemon.NotifyAsync;
        if (this._tray)
            delete this._tray._showNotification;
        this._daemon = null;
        this._tray = null;
    }
}
