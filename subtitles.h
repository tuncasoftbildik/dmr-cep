/*
    Copyright (C) 2026 DroidStar-DMR contributors

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

#ifndef SUBTITLES_H
#define SUBTITLES_H

#include <QObject>
#include <QString>
#include <QTimer>
#include <QVariantMap>
#include <cstdint>

// Live subtitles ("altyazı") for received transmissions.
//
// SubtitleTap: called from the DMR mode thread (DMR::record_rx / finish_recording). wants() is
// checked once per transmission; push() only hands the samples to the Swift engine
// (SubtitleEngine.swift), which queues them and never blocks the caller.
//
// SubtitleController: Qt-thread side. Owns the settings, receives the engine's JSON callbacks
// (queued to the Qt thread), exposes the live caption to QML (droidStar.subtitles) and writes the
// final text next to the recording as <recording>.json.
namespace SubtitleTap {
bool supported();                         // iOS 26+ (SpeechAnalyzer)
bool wants(uint32_t dst);                 // subtitles on and dst is a subtitle TG
void begin(uint32_t src, uint32_t dst, const QString &key);
void push(const int16_t *pcm, int n);
void end();
}

class SubtitleController : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool supported READ supported CONSTANT)
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY settingsChanged)
    Q_PROPERTY(QString talkgroups READ talkgroups WRITE setTalkgroups NOTIFY settingsChanged)
    Q_PROPERTY(bool translate READ translate WRITE setTranslate NOTIFY settingsChanged)
    Q_PROPERTY(bool showOriginal READ showOriginal WRITE setShowOriginal NOTIFY settingsChanged)
    Q_PROPERTY(QString language READ language WRITE setLanguage NOTIFY settingsChanged)
    Q_PROPERTY(QString modelStatus READ modelStatus NOTIFY statusChanged)
    Q_PROPERTY(double modelProgress READ modelProgress NOTIFY statusChanged)
    Q_PROPERTY(QString translationStatus READ translationStatus NOTIFY statusChanged)
    // Live caption
    Q_PROPERTY(bool active READ active NOTIFY captionChanged)          // an over is being captioned
    Q_PROPERTY(bool showing READ showing NOTIFY captionChanged)        // active, or finished < 8 s ago
    Q_PROPERTY(QString en READ en NOTIFY captionChanged)
    Q_PROPERTY(QString enVolatile READ enVolatile NOTIFY captionChanged)
    Q_PROPERTY(QString tr READ tr NOTIFY captionChanged)
    Q_PROPERTY(QString trVolatile READ trVolatile NOTIFY captionChanged)
    Q_PROPERTY(uint src READ src NOTIFY captionChanged)

public:
    explicit SubtitleController(QObject *parent = nullptr);
    static SubtitleController *instance() { return s_instance; }

    bool supported() const;
    bool enabled() const { return m_enabled; }
    QString talkgroups() const { return m_talkgroups; }
    bool translate() const { return m_translate; }
    bool showOriginal() const { return m_showOriginal; }
    QString language() const { return m_language; }
    void setEnabled(bool on);
    void setTalkgroups(const QString &tgs);
    void setTranslate(bool on);
    void setShowOriginal(bool on);
    void setLanguage(const QString &lang);

    QString modelStatus() const { return m_modelStatus; }
    double modelProgress() const { return m_modelProgress; }
    QString translationStatus() const { return m_translationStatus; }

    bool active() const { return m_active; }
    bool showing() const { return m_active || m_holdTimer.isActive(); }
    QString en() const { return m_en; }
    QString enVolatile() const { return m_enV; }
    QString tr() const { return m_tr; }
    QString trVolatile() const { return m_trV; }
    uint src() const { return m_src; }

    Q_INVOKABLE bool tgHasSubtitles(const QString &tg) const;
    Q_INVOKABLE void setTgSubtitles(const QString &tg, bool on);
    Q_INVOKABLE void openTranslationDownload();
    Q_INVOKABLE void refreshStatus();

    // <recording>.json next to <recording>.wav: { en, tr, lang }. Empty map if none.
    static QVariantMap readSidecar(const QString &wavPath);

    void handleEvent(const QByteArray &json);   // Qt thread

signals:
    void settingsChanged();
    void statusChanged();
    void captionChanged();
    void subtitleSaved(QString wavPath);

private:
    void save();
    void apply();
    void writeSidecar(const QVariantMap &ev);

    static SubtitleController *s_instance;

    bool m_enabled = true;
    QString m_talkgroups = "91";
    bool m_translate = true;
    bool m_showOriginal = true;
    QString m_language = "en";

    QString m_modelStatus = "unknown";
    double m_modelProgress = 0;
    QString m_translationStatus = "unknown";

    bool m_active = false;
    QString m_key;
    QString m_en, m_enV, m_tr, m_trV;
    uint m_src = 0;
    QTimer m_holdTimer;
};

#endif // SUBTITLES_H
