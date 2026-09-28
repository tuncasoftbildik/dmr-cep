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

#ifndef RXRECORDER_H
#define RXRECORDER_H

#include <QByteArray>
#include <QString>
#include <cstddef>
#include <cstdint>

// Collects the decoded 8 kHz mono PCM of one received transmission and writes it
// as a WAV file when the transmission ends, so it can be replayed from the QSO page.
// File name: <yyyyMMdd-HHmmss-zzz>_<srcid>_<dstid>.wav in recordingsDir().
class RxRecorder
{
public:
    static const int kSampleRate = 8000;
    static const int kMaxFiles = 30;
    static const int kMinMs = 1000;           // shorter transmissions (kerchunks) are not kept
    static const int kMaxSeconds = 300;       // hard cap per transmission

    static QString recordingsDir();

    bool active() const { return m_active; }
    uint32_t streamSrc() const { return m_src; }
    uint32_t streamDst() const { return m_dst; }

    void begin(uint32_t src, uint32_t dst);
    void append(const int16_t *pcm, size_t samples);
    // Writes the file if long enough. Returns the file path, or an empty string when nothing was saved.
    QString finish();

    // Write an 8 kHz mono recording with the standard name (also used for our own TX, decoded as
    // the other side hears it). Returns the path, or empty if shorter than kMinMs.
    static QString writeRecording(uint32_t src, uint32_t dst, qint64 startMs, const QByteArray &pcm);

private:
    static void prune();

    bool m_active = false;
    uint32_t m_src = 0;
    uint32_t m_dst = 0;
    qint64 m_startMs = 0;
    QByteArray m_pcm;
};

#endif // RXRECORDER_H
