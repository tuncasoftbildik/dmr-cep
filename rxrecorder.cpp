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

#include "rxrecorder.h"

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QStandardPaths>
#include <QtEndian>

QString RxRecorder::recordingsDir()
{
    return QStandardPaths::writableLocation(QStandardPaths::AppDataLocation) + "/recordings";
}

void RxRecorder::begin(uint32_t src, uint32_t dst)
{
    m_active = true;
    m_src = src;
    m_dst = dst;
    m_startMs = QDateTime::currentMSecsSinceEpoch();
    m_pcm.clear();
    m_pcm.reserve(kSampleRate * 2 * 20);
}

void RxRecorder::append(const int16_t *pcm, size_t samples)
{
    if (!m_active) return;
    if (m_pcm.size() >= kSampleRate * 2 * kMaxSeconds) return;
    for (size_t i = 0; i < samples; ++i) {
        const int16_t le = qToLittleEndian(pcm[i]);
        m_pcm.append(reinterpret_cast<const char *>(&le), 2);
    }
}

static void putLE32(QByteArray &b, quint32 v) { v = qToLittleEndian(v); b.append(reinterpret_cast<const char *>(&v), 4); }
static void putLE16(QByteArray &b, quint16 v) { v = qToLittleEndian(v); b.append(reinterpret_cast<const char *>(&v), 2); }

QString RxRecorder::finish()
{
    if (!m_active) return QString();
    m_active = false;
    const QString path = writeRecording(m_src, m_dst, m_startMs, m_pcm);
    m_pcm.clear();
    return path;
}

QString RxRecorder::writeRecording(uint32_t src, uint32_t dst, qint64 startMs, const QByteArray &pcm)
{
    const qint64 durMs = (qint64)pcm.size() * 1000 / (kSampleRate * 2);
    if (durMs < kMinMs) return QString();

    QDir().mkpath(recordingsDir());
    const QString name = QDateTime::fromMSecsSinceEpoch(startMs).toString("yyyyMMdd-HHmmss-zzz")
                         + "_" + QString::number(src) + "_" + QString::number(dst) + ".wav";
    const QString path = recordingsDir() + "/" + name;

    QByteArray hdr;
    hdr.append("RIFF");
    putLE32(hdr, 36 + pcm.size());
    hdr.append("WAVE");
    hdr.append("fmt ");
    putLE32(hdr, 16);
    putLE16(hdr, 1);                    // PCM
    putLE16(hdr, 1);                    // mono
    putLE32(hdr, kSampleRate);
    putLE32(hdr, kSampleRate * 2);      // byte rate
    putLE16(hdr, 2);                    // block align
    putLE16(hdr, 16);                   // bits per sample
    hdr.append("data");
    putLE32(hdr, pcm.size());

    QFile f(path);
    if (!f.open(QIODevice::WriteOnly)) {
        qDebug() << "RxRecorder: cannot write" << path << f.errorString();
        return QString();
    }
    f.write(hdr);
    f.write(pcm);
    f.close();

    prune();
    return path;
}

void RxRecorder::prune()
{
    QDir dir(recordingsDir());
    // Names start with a timestamp, so name order is chronological.
    QStringList files = dir.entryList(QStringList() << "*.wav", QDir::Files, QDir::Name | QDir::Reversed);
    for (int i = kMaxFiles; i < files.size(); ++i) {
        dir.remove(files.at(i));
    }
}
