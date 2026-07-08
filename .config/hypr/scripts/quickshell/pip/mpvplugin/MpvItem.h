#pragma once

#include <MpvQt/mpvabstractitem.h>
#include <QtQml/qqml.h>

// Minimal concrete mpv item for QML. mpvqt's MpvAbstractItem does all the
// libmpv<->QtQuick render work; we just register it as a QML element and set
// sensible PiP defaults + an IPC socket so ani-cli / mov-cli / pip_mpv.sh load
// into THIS embedded player.
class MpvItem : public MpvAbstractItem
{
    Q_OBJECT
    QML_ELEMENT
public:
    explicit MpvItem(QQuickItem *parent = nullptr);
};
