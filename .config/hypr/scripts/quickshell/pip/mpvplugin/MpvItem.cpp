#include "MpvItem.h"

#include <QString>

MpvItem::MpvItem(QQuickItem *parent)
    : MpvAbstractItem(parent)
{
    // mpv is initialised by the time `ready()` fires; configure it then.
    connect(this, &MpvAbstractItem::ready, this, [this]() {
        setProperty(QStringLiteral("terminal"), QStringLiteral("no"));
        setProperty(QStringLiteral("keep-open"), QStringLiteral("yes"));
        setProperty(QStringLiteral("idle"), QStringLiteral("yes"));
        setProperty(QStringLiteral("osc"), QStringLiteral("no"));
        setProperty(QStringLiteral("ytdl"), QStringLiteral("yes"));
        setProperty(QStringLiteral("hwdec"), QStringLiteral("auto-safe"));

        // IPC socket: the same one ani-cli/lobster/pip_mpv.sh target, so the
        // background resolver loads straight into this embedded player.
        const QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR", QStringLiteral("/tmp"));
        setProperty(QStringLiteral("input-ipc-server"), runtime + QStringLiteral("/mpv-pip.sock"));
    });
}
