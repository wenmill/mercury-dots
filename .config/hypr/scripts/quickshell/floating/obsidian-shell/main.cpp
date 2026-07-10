// obsidian-shell — the floating panel as a single layer-shell + WebEngine window.
//
// Replaces the Quickshell `Floating.qml` panel AND the sibling PyQt6 obsidian
// window with ONE wlr-layer-shell surface that hosts the three web hubs
// (Obsidian / Hermes / Dify) directly. The full edge-peek / morph / drag-snap /
// selector chrome of Floating.qml is ported into qml/Floating.qml; this
// file just builds the layer surface and exposes three small helpers to QML:
//
//   sh         — run a detached shell command (replaces Quickshell.execDetached
//                and the old PyQt Bridge: Hermes dashboard bring-up, etc.)
//   maskHelper — apply a dynamic input region to the surface so the overlay is
//                click-through everywhere except the strip/peek/expanded panel
//                (replaces Quickshell's declarative `mask: Region{}`)
//   qsColors   — the live matugen palette (same qs_colors.json the shell reads)

#include <optional>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QtWebEngineQuick/QtWebEngineQuick>
#include <QEvent>
#include <QProcess>
#include <QRegion>
#include <QRect>
#include <QFile>
#include <QTimer>
#include <QJsonDocument>
#include <QJsonObject>
#include <QVariantMap>
#include <QVariantList>
#include <QString>
#include <QUrl>
#include <QDir>

#include <LayerShellQt/Shell>
#include <LayerShellQt/Window>

// Run shell commands detached, on behalf of QML (Hermes dashboard, etc.).
class Sh : public QObject {
    Q_OBJECT
public:
    Q_INVOKABLE void run(const QString &cmd) {
        QProcess::startDetached("bash", {"-c", cmd});
    }
    // Async output capture: run `cmd`, then emit fetched(tag, stdout) when it
    // exits. Used by the Hermes sessions panel to pull /api/sessions (the token
    // is fetched from the keyring inside the command, so it never touches QML).
    // Never blocks the GUI thread; the QProcess self-deletes on completion.
    Q_INVOKABLE void fetch(const QString &tag, const QString &cmd) {
        QProcess *p = new QProcess(this);
        connect(p, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                this, [this, p, tag](int, QProcess::ExitStatus) {
            emit fetched(tag, QString::fromUtf8(p->readAllStandardOutput()));
            p->deleteLater();
        });
        connect(p, &QProcess::errorOccurred, this, [this, p, tag](QProcess::ProcessError) {
            emit fetched(tag, QString());
            p->deleteLater();
        });
        p->start("bash", {"-c", cmd});
    }
signals:
    void fetched(const QString &tag, const QString &out);
};

// Apply a dynamic input region (click-through mask) to the layer surface. QML
// hands us a flat [x,y,w,h, x,y,w,h, ...] list; we union the rects and call
// QQuickWindow::setMask, which Qt maps to the wl_surface input region. Skips the
// commit when the region is unchanged so animated bindings don't thrash the
// compositor frame-by-frame.
class MaskHelper : public QObject {
    Q_OBJECT
public:
    void setWindow(QQuickWindow *w) { m_win = w; }
    Q_INVOKABLE void apply(const QVariantList &flat) {
        if (!m_win) return;
        QRegion r;
        for (int i = 0; i + 3 < flat.size(); i += 4) {
            int x = flat[i].toInt(), y = flat[i + 1].toInt();
            int w = flat[i + 2].toInt(), h = flat[i + 3].toInt();
            if (w > 0 && h > 0) r += QRect(x, y, w, h);
        }
        if (r == m_last) return;
        m_last = r;
        m_win->setMask(r);
    }
private:
    QQuickWindow *m_win = nullptr;
    QRegion m_last;
};

// Keyboard focus for the layer surface, driven from QML.
//
// The panel is an overlay that spends almost all of its life invisible and
// click-through, so it must not hold keyboard focus while idle. LayerShellQt
// defaults activateOnShow to true ("Normally, you want this enabled"), which is
// wrong here: combined with a keyboard-interactive surface, the panel asks the
// compositor for focus the moment it maps. At login nothing else holds focus,
// so it gets it, and every keystroke vanishes into a hidden WebEngine until the
// user peeks the selector and focus moves elsewhere.
//
// The surface therefore maps with KeyboardInteractivityNone and activateOnShow
// off, and QML raises it only while the expanded panel is on screen — the one
// state in which anything here wants typing.
class KeyboardHelper : public QObject {
    Q_OBJECT
public:
    // QML runs during engine.load(), before main() has a window to hand us — the
    // same ordering the input-mask code works around. A command already sitting
    // in the cmdfile therefore opens the panel before setWindow(), so remember
    // what was asked for and apply it the moment the window arrives.
    void setWindow(QWindow *w) {
        m_win = w;
        if (m_pending) { bool want = *m_pending; m_pending.reset(); setInteractive(want); }
    }
    // Exclusive, not OnDemand, while the panel is open. OnDemand only hands the
    // keyboard over when the surface is CLICKED — verified against Hyprland: no
    // `activelayer` event fires when the panel is opened from its keybind — so
    // typing would silently go to the window underneath. Exclusive takes the
    // keyboard for as long as the panel is up, which is what an open notes/chat
    // panel wants, and None gives it straight back on close.
    Q_INVOKABLE void setInteractive(bool on) {
        if (!m_win) { m_pending = on; return; }
        if (on == m_last) return;
        if (auto *ls = LayerShellQt::Window::get(m_win)) {
            ls->setKeyboardInteractivity(
                on ? LayerShellQt::Window::KeyboardInteractivityExclusive
                   : LayerShellQt::Window::KeyboardInteractivityNone);
            m_last = on;
        }
    }
private:
    QWindow *m_win = nullptr;
    bool m_last = false;                 // matches the None we map with
    std::optional<bool> m_pending;       // requested before the window existed
};

// Watch the layer surface for the compositor pointer entering/leaving its input
// region, and report it to QML. This is the AUTHORITATIVE "cursor is over the
// overlay" signal: unlike a QML HoverHandler — which sits under the in-scene
// WebEngineView and can miss a hover-leave (Chromium grabs the pointer while a
// page is hydrating, so the parent never sees the leave and the panel won't
// auto-close on mouse-off, most noticeably right after a restart) — a window
// QEvent::Leave comes straight from the compositor when the cursor exits the
// masked region, and can't be swallowed by the web view. QML force-closes the
// (unpinned) panel off this.
class SurfaceWatch : public QObject {
    Q_OBJECT
public:
    void setWindow(QQuickWindow *w) { m_win = w; if (w) w->installEventFilter(this); }
    bool eventFilter(QObject *o, QEvent *e) override {
        if (o == m_win) {
            if (e->type() == QEvent::Enter) emit entered();
            else if (e->type() == QEvent::Leave) emit left();
        }
        return QObject::eventFilter(o, e);
    }
signals:
    void entered();
    void left();
private:
    QQuickWindow *m_win = nullptr;
};

// Poll a small state file and emit its trimmed contents whenever they CHANGE.
// QML's file:// XMLHttpRequest doesn't read these reliably in this build, and
// QFileSystemWatcher drops events under rapid truncate/rewrite — a steady QTimer
// poll (C++ QFile reads work fine) is the robust path. clear() truncates the
// file and resets the last-seen value so the same command can be sent again.
class FileWatch : public QObject {
    Q_OBJECT
public:
    Q_INVOKABLE void watch(const QString &path, int intervalMs) {
        m_path = path;
        QFile f(path);
        if (!f.exists()) { if (f.open(QIODevice::WriteOnly)) f.close(); }
        connect(&m_timer, &QTimer::timeout, this, &FileWatch::poll);
        m_timer.start(intervalMs > 0 ? intervalMs : 200);
        poll();
    }
    Q_INVOKABLE void clear() {
        QFile f(m_path);
        if (f.open(QIODevice::WriteOnly | QIODevice::Truncate)) f.close();
        m_last.clear();
    }
signals:
    void changed(const QString &content);
private slots:
    void poll() {
        QFile f(m_path);
        if (!f.open(QIODevice::ReadOnly)) return;
        QString c = QString::fromUtf8(f.readAll()).trimmed();
        if (c == m_last) return;   // edge-trigger: only on change
        m_last = c;
        emit changed(c);
    }
private:
    QTimer m_timer;
    QString m_path;
    QString m_last;
};

static QVariantMap loadColors(const QString &path) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return {};
    auto doc = QJsonDocument::fromJson(f.readAll());
    return doc.isObject() ? doc.object().toVariantMap() : QVariantMap();
}

static QString readText(const QString &path) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return {};
    return QString::fromUtf8(f.readAll());
}

int main(int argc, char *argv[])
{
    // Keep Chromium painting while the overlay is unfocused — otherwise an
    // occluded surface clears to opaque black over the matugen frame.
    //
    // --disable-gpu-compositing: force Chromium to hand its final frame to Qt as
    // a scene-graph texture instead of compositing into its OWN Wayland
    // subsurface. The subsurface path renders ABOVE every QML sibling regardless
    // of declaration order / z, which is why the selector strip used to disappear
    // behind the web view. With in-scene rendering, normal QML z-order applies and
    // the selector (declared after the web views) draws on top. GPU rasterization
    // of page content is unaffected; only the compositing step moves to Qt.
    qputenv("QTWEBENGINE_CHROMIUM_FLAGS",
            "--disable-renderer-backgrounding "
            "--disable-backgrounding-occluded-windows "
            "--disable-background-timer-throttling "
            "--disable-gpu-compositing");

    // Both must run before the QGuiApplication is constructed.
    QtWebEngineQuick::initialize();
    LayerShellQt::Shell::useLayerShell();

    QGuiApplication app(argc, argv);
    app.setApplicationName("obsidian-shell");
    app.setDesktopFileName("obsidian-shell");

    const QString here = QStringLiteral(SOURCE_DIR);
    // qs_colors.json lives two dirs up (…/quickshell/qs_colors.json), same file
    // MatugenColors.qml / notes_overlay.py read.
    const QString colorsPath =
        QDir(here).absoluteFilePath("../../qs_colors.json");

    QQmlApplicationEngine engine;
    Sh sh;
    MaskHelper maskHelper;
    KeyboardHelper keyboardHelper;
    SurfaceWatch surfaceWatch;
    FileWatch cmdWatch, passWatch;
    engine.rootContext()->setContextProperty("sh", &sh);
    engine.rootContext()->setContextProperty("maskHelper", &maskHelper);
    engine.rootContext()->setContextProperty("kb", &keyboardHelper);
    engine.rootContext()->setContextProperty("surfaceWatch", &surfaceWatch);
    engine.rootContext()->setContextProperty("cmdWatch", &cmdWatch);
    engine.rootContext()->setContextProperty("passWatch", &passWatch);
    engine.rootContext()->setContextProperty("homeDir", QDir::homePath());
    engine.rootContext()->setContextProperty("qsColors", loadColors(colorsPath));
    // Prepend the live matugen palette so the transparency scripts colour their
    // 10% panel tints from window.QS_COLORS (same palette the bar uses).
    QString rawColors = readText(colorsPath).trimmed();
    if (rawColors.isEmpty()) rawColors = "{}";
    const QString jsPrefix = "window.QS_COLORS = " + rawColors + ";\n";
    engine.rootContext()->setContextProperty(
        "injectJs", jsPrefix + readText(QDir(here).absoluteFilePath("../obsidian_transparent.js")));
    engine.rootContext()->setContextProperty(
        "hermesZenJs", jsPrefix + readText(QDir(here).absoluteFilePath("../hermes_zen.js")));
    engine.rootContext()->setContextProperty(
        "difyJs", jsPrefix + readText(QDir(here).absoluteFilePath("../dify_transparent.js")));

    const QString qmlPath = QDir(here).absoluteFilePath("qml/Floating.qml");
    engine.load(QUrl::fromLocalFile(qmlPath));
    if (engine.rootObjects().isEmpty())
        return 1;

    auto *win = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
    if (!win) return 2;
    maskHelper.setWindow(win);
    surfaceWatch.setWindow(win);

    // Layer-shell surface: a full-width overlay docked to the bottom, left and
    // right edges (NOT the top), leaving the 60px topbar clear — exactly
    // Floating.qml's `anchors{top:false;bottom:true;left:true;right:true}` +
    // height = screen.height-60. Height comes from the QML window (Screen-60).
    if (auto *ls = LayerShellQt::Window::get(win)) {
        ls->setScope(QStringLiteral("qs-floating-overlay"));
        ls->setLayer(LayerShellQt::Window::LayerOverlay);
        ls->setAnchors(LayerShellQt::Window::Anchors(
            LayerShellQt::Window::AnchorBottom |
            LayerShellQt::Window::AnchorLeft |
            LayerShellQt::Window::AnchorRight));
        ls->setExclusiveZone(0);  // overlay; reserve no screen space
        // Map without the keyboard. QML raises this to OnDemand while the
        // expanded panel is up; see KeyboardHelper.
        ls->setKeyboardInteractivity(
            LayerShellQt::Window::KeyboardInteractivityNone);
        // ...and do not requestActivate on show. LayerShellQt defaults this to
        // true ("Normally, you want this enabled"), which is wrong for a mostly
        // invisible overlay: at login nothing else holds focus, so the panel
        // takes it and swallows every keystroke.
        ls->setActivateOnShow(false);
    }
    keyboardHelper.setWindow(win);

    win->setVisible(true);
    return app.exec();
}

#include "main.moc"
