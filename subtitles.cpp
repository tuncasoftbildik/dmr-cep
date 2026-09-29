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

#include "subtitles.h"
#include "rxrecorder.h"

#include <QDebug>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSet>
#include <QSettings>
#include <algorithm>
#include <atomic>
#include <mutex>

#if defined(Q_OS_IOS)
// Implemented in Swift (SubtitleEngine.swift / SubtitleTranslationUI.swift, @_cdecl).
extern "C" {
typedef void (*ds_subtitle_callback)(const char *json);
int32_t ds_subtitle_supported(void);
void ds_subtitle_set_callback(ds_subtitle_callback cb);
void ds_subtitle_configure(int32_t enabled, int32_t translate, const char *language);
void ds_subtitle_refresh_status(void);
void ds_subtitle_begin(uint32_t src, uint32_t dst, const char *key);
void ds_subtitle_push_pcm(const int16_t *pcm, int32_t n);
void ds_subtitle_end(void);
void ds_subtitle_open_translation_download(void);
}
#endif

// ---------------------------------------------------------------------------------------------
// Mode-thread side
// ---------------------------------------------------------------------------------------------

namespace {
std::atomic<bool> g_enabled{false};
std::mutex g_tgMutex;
QSet<uint32_t> g_tgs;

QSet<uint32_t> parseTgs(const QString &s)
{
    QSet<uint32_t> out;
    const QStringList parts = s.split(QRegularExpression("[^0-9]+"), Qt::SkipEmptyParts);
    for (const QString &p : parts) {
        bool ok = false;
        const uint v = p.toUInt(&ok);
        if (ok && v > 0) out.insert(v);
    }
    return out;
}
}

bool SubtitleTap::supported()
{
#if defined(Q_OS_IOS)
    static const bool s = ds_subtitle_supported() != 0;
    return s;
#else
    return false;
#endif
}

bool SubtitleTap::wants(uint32_t dst)
{
    if (!g_enabled.load(std::memory_order_relaxed) || !supported()) return false;
    std::lock_guard<std::mutex> lk(g_tgMutex);   // once per transmission, never contended for long
    return g_tgs.contains(dst);
}

void SubtitleTap::begin(uint32_t src, uint32_t dst, const QString &key)
{
#if defined(Q_OS_IOS)
    ds_subtitle_begin(src, dst, key.toUtf8().constData());
#else
    Q_UNUSED(src) Q_UNUSED(dst) Q_UNUSED(key)
#endif
}

void SubtitleTap::push(const int16_t *pcm, int n)
{
#if defined(Q_OS_IOS)
    ds_subtitle_push_pcm(pcm, n);
#else
    Q_UNUSED(pcm) Q_UNUSED(n)
#endif
}

void SubtitleTap::end()
{
#if defined(Q_OS_IOS)
    ds_subtitle_end();
#endif
}

// ---------------------------------------------------------------------------------------------
// Qt-thread side
// ---------------------------------------------------------------------------------------------

SubtitleController *SubtitleController::s_instance = nullptr;

#if defined(Q_OS_IOS)
static void engineCallback(const char *json)
{
    // Any thread: copy and hop to the Qt thread.
    SubtitleController *c = SubtitleController::instance();
    if (!c || !json) return;
    const QByteArray data(json);
    QMetaObject::invokeMethod(c, [c, data]() { c->handleEvent(data); }, Qt::QueuedConnection);
}
#endif

SubtitleController::SubtitleController(QObject *parent) : QObject(parent)
{
    s_instance = this;
    QSettings s;
    s.beginGroup("Subtitles");
    m_enabled = s.value("enabled", true).toBool();
    m_talkgroups = s.value("talkgroups", "91").toString();
    m_translate = s.value("translate", true).toBool();
    // Original English line is off by default; v2 key turns it off once for existing installs.
    m_showOriginal = s.value("showOriginalV2", false).toBool();
    m_language = s.value("language", "en").toString() == "tr" ? "tr" : "en";
    s.endGroup();

    m_holdTimer.setSingleShot(true);
    m_holdTimer.setInterval(8000);      // keep the last caption on screen after the over
    connect(&m_holdTimer, &QTimer::timeout, this, &SubtitleController::captionChanged);

#if defined(Q_OS_IOS)
    if (supported()) {
        ds_subtitle_set_callback(engineCallback);
    } else {
        m_modelStatus = "unavailable";
        m_translationStatus = "unavailable";
    }
#else
    m_modelStatus = "unavailable";
    m_translationStatus = "unavailable";
#endif
    apply();
}

bool SubtitleController::supported() const { return SubtitleTap::supported(); }

void SubtitleController::save()
{
    QSettings s;
    s.beginGroup("Subtitles");
    s.setValue("enabled", m_enabled);
    s.setValue("talkgroups", m_talkgroups);
    s.setValue("translate", m_translate);
    s.setValue("showOriginalV2", m_showOriginal);
    s.setValue("language", m_language);
    s.endGroup();
}

void SubtitleController::apply()
{
    {
        std::lock_guard<std::mutex> lk(g_tgMutex);
        g_tgs = parseTgs(m_talkgroups);
    }
    g_enabled.store(m_enabled);
#if defined(Q_OS_IOS)
    if (supported()) {
        ds_subtitle_configure(m_enabled ? 1 : 0, m_translate ? 1 : 0, m_language.toUtf8().constData());
    }
#endif
    qDebug() << "Subtitles: enabled" << m_enabled << "TGs" << m_talkgroups << "translate" << m_translate
             << "language" << m_language << "supported" << supported();
}

void SubtitleController::setEnabled(bool on)
{
    if (on == m_enabled) return;
    m_enabled = on;
    save(); apply();
    emit settingsChanged();
}

void SubtitleController::setTalkgroups(const QString &tgs)
{
    // Normalized: "91, 2862"
    QList<uint32_t> list = parseTgs(tgs).values();
    std::sort(list.begin(), list.end());
    QStringList parts;
    for (uint32_t v : list) parts << QString::number(v);
    const QString norm = parts.join(", ");
    if (norm == m_talkgroups) return;
    m_talkgroups = norm;
    save(); apply();
    emit settingsChanged();
}

void SubtitleController::setTranslate(bool on)
{
    if (on == m_translate) return;
    m_translate = on;
    save(); apply();
    emit settingsChanged();
}

void SubtitleController::setShowOriginal(bool on)
{
    if (on == m_showOriginal) return;
    m_showOriginal = on;
    save();
    emit settingsChanged();
}

void SubtitleController::setLanguage(const QString &lang)
{
    const QString l = (lang == "tr") ? "tr" : "en";
    if (l == m_language) return;
    m_language = l;
    save(); apply();
    emit settingsChanged();
}

bool SubtitleController::tgHasSubtitles(const QString &tg) const
{
    return parseTgs(m_talkgroups).contains(tg.toUInt());
}

void SubtitleController::setTgSubtitles(const QString &tg, bool on)
{
    const uint v = tg.toUInt();
    if (v == 0) return;
    QSet<uint32_t> set = parseTgs(m_talkgroups);
    if (on) set.insert(v); else set.remove(v);
    QStringList parts;
    for (uint32_t x : set) parts << QString::number(x);
    setTalkgroups(parts.join(","));
}

void SubtitleController::openTranslationDownload()
{
#if defined(Q_OS_IOS)
    ds_subtitle_open_translation_download();
#endif
}

void SubtitleController::refreshStatus()
{
#if defined(Q_OS_IOS)
    if (supported()) ds_subtitle_refresh_status();
#endif
}

void SubtitleController::handleEvent(const QByteArray &json)
{
    const QVariantMap ev = QJsonDocument::fromJson(json).object().toVariantMap();
    const QString type = ev.value("t").toString();

    if (type == "status") {
        m_modelStatus = ev.value("model").toString();
        m_modelProgress = ev.value("progress").toDouble();
        m_translationStatus = ev.value("translation").toString();
        if (ev.contains("error")) qDebug() << "Subtitles: model error" << ev.value("error").toString();
        emit statusChanged();
        return;
    }

    const QString key = ev.value("key").toString();
    if (type == "begin") {
        m_holdTimer.stop();
        m_active = true;
        m_key = key;
        m_src = ev.value("src").toUInt();
        m_en.clear(); m_enV.clear(); m_tr.clear(); m_trV.clear();
        emit captionChanged();
        return;
    }
    if (type == "error") {
        qDebug() << "Subtitles: engine error" << key << ev.value("error").toString();
        if (key == m_key && m_active) {
            m_active = false;
            emit captionChanged();
        }
        return;
    }
    if (type == "partial" || type == "final") {
        const bool current = (key == m_key);
        if (current) {
            m_en = ev.value("en").toString();
            m_enV = ev.value("enV").toString();
            m_tr = ev.value("tr").toString();
            m_trV = ev.value("trV").toString();
        }
        if (type == "final") {
            qDebug().noquote() << "Subtitles: final" << key
                               << QString("audio %1 s, first text %2 ms, finalize %3 ms")
                                      .arg(ev.value("audio").toDouble(), 0, 'f', 1)
                                      .arg(ev.value("firstMs").toDouble(), 0, 'f', 0)
                                      .arg(ev.value("finalizeMs").toDouble(), 0, 'f', 0);
            writeSidecar(ev);
            if (current) {
                m_active = false;
                if (!m_en.isEmpty() || !m_tr.isEmpty()) m_holdTimer.start();
            }
        }
        if (current) emit captionChanged();
    }
}

void SubtitleController::writeSidecar(const QVariantMap &ev)
{
    const QString key = ev.value("key").toString();
    const QString en = ev.value("en").toString();
    const QString tr = ev.value("tr").toString();
    if (key.isEmpty() || key.contains('/') || (en.isEmpty() && tr.isEmpty())) return;
    const QString base = RxRecorder::recordingsDir() + "/" + key;
    // Only next to a kept recording (kerchunks under 1 s are not saved).
    if (!QFileInfo::exists(base + ".wav")) return;
    QJsonObject o;
    o["en"] = en;
    o["tr"] = tr;
    o["lang"] = ev.value("lang").toString();
    o["src"] = ev.value("src").toDouble();
    o["dst"] = ev.value("dst").toDouble();
    QFile f(base + ".json");
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        qDebug() << "Subtitles: cannot write" << f.fileName();
        return;
    }
    f.write(QJsonDocument(o).toJson(QJsonDocument::Compact));
    f.close();
    emit subtitleSaved(base + ".wav");
}

QVariantMap SubtitleController::readSidecar(const QString &wavPath)
{
    QString p = wavPath;
    if (p.endsWith(".wav")) p.chop(4);
    QFile f(p + ".json");
    if (!f.open(QIODevice::ReadOnly)) return QVariantMap();
    return QJsonDocument::fromJson(f.readAll()).object().toVariantMap();
}
