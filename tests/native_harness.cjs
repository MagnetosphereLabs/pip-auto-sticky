// Execute the actual generated scripts against small compositor API doubles.
const fs = require('node:fs');
const vm = require('node:vm');
const [backend, directory, fixture, mode] = process.argv.slice(2);
const types = { NORMAL: 0, DIALOG: 3, UTILITY: 7 };
function signal() {
    const callbacks = [];
    return { connect: callback => callbacks.push(callback), emit: () => callbacks.forEach(cb => cb()) };
}
const windows = JSON.parse(fs.readFileSync(fixture, 'utf8')).map(w => {
    const signals = new Map();
    return {
        ...w,
        resourceClass: w.app_id, caption: w.title,
        normalWindow: !w.kind || w.kind === 'NORMAL',
        dialog: w.kind === 'DIALOG', utility: w.kind === 'UTILITY',
        modal: !!w.modal, keepAbove: false, onAllDesktops: false,
        captionChanged: signal(), windowClassChanged: signal(),
        windowRoleChanged: signal(), desktopFileNameChanged: signal(),
        keepAboveChanged: signal(), desktopsChanged: signal(), closed: signal(),
        get_title() { return this.caption; },
        get_wm_class() { return this.app_id; },
        get_window_type() { return types[w.kind || 'NORMAL']; },
        is_modal() { return this.modal; },
        connect(name, callback) { signals.set(name, callback); return name; },
        disconnect(name) { signals.delete(name); },
        emit(name) { signals.get(name)?.(); },
        is_above() { return this.keepAbove; },
        is_on_all_workspaces() { return this.onAllDesktops; },
        make_above() { this.keepAbove = true; },
        stick() { this.onAllDesktops = true; },
        unmake_above() { this.keepAbove = false; },
        unstick() { this.onAllDesktops = false; },
    };
});
const context = vm.createContext({
    workspace: { stackingOrder: windows, windowAdded: signal() },
    global: { display: { list_all_windows: () => windows, connect: () => 1, disconnect() {} } },
    Meta: { WindowType: types }, Extension: class {}, print() {}, console: { log() {} },
});
if (backend === 'kwin') {
    vm.runInContext(fs.readFileSync(directory + '/kwin/contents/code/main.js', 'utf8'), context);
} else {
    const code = fs.readFileSync(directory + '/gnome/extension.js', 'utf8')
        .replace(/^import .*;$/gm, '').replace('export default class', 'class');
    vm.runInContext(code + '\nconst extension = new PipStickyExtension(); extension.enable();', context);
}
const managed = () => windows.filter(w => w.keepAbove && w.onAllDesktops).map(w => w.id);
const changed = w => backend === 'kwin' ? w.captionChanged.emit() : w.emit('notify::title');
if (mode === 'lifecycle') {
    const result = { initial: managed() };
    windows[0].caption = 'Vesktop';
    changed(windows[0]);
    result.late = managed();
    windows[1].caption = 'Vesktop';
    windows[1].keepAbove = false;
    windows[1].onAllDesktops = false;
    changed(windows[1]);
    result.renamed = managed();
    const closed = windows.pop();
    if (backend === 'kwin') closed.closed.emit(); else closed.emit('unmanaged');
    result.closed = managed();
    if (backend === 'gnome') vm.runInContext('extension.disable()', context);
    process.stdout.write(JSON.stringify(result));
} else {
    process.stdout.write(JSON.stringify(managed()));
}
