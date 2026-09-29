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

#ifndef APRSBEACON_H
#define APRSBEACON_H

#include <QObject>
#include <QString>
#include <QTcpSocket>
#include <QTimer>

// Sends the phone position to APRS-IS (shows up on aprs.fi) as <callsign>-7 while enabled.
// Only runs when the user turns it on; off by default. Beacons on the first fix, when moved
// kMinMoveMeters (at most every kMinIntervalMs) and otherwise every kMaxIntervalMs.
// Lives on the GUI thread.
class AprsBeacon : public QObject
{
    Q_OBJECT
public:
    explicit AprsBeacon(QObject *parent = nullptr);

    void set_enabled(bool on);
    bool enabled() const { return m_enabled; }
    void set_callsign(const QString &callsign);
    // Free text after the position (UTF-8, max 43 chars). A change is sent right away.
    void set_comment(const QString &comment);
    // Two characters: symbol table ('/' or '\\') + symbol code, e.g. "/[" person, "/>" car.
    void set_symbol(const QString &symbol);
    static QString clean_comment(const QString &comment);
    // Latest phone fix; beacons if due.
    void update_position(double lat, double lon);
    // Short English status for the settings page, e.g. "Sent 09:58 as TB1BDL-7".
    QString status_text() const;

    static int passcode(const QString &callsign);
    static QString format_position(double lat, double lon);

signals:
    void status_changed();

private:
    void connect_server();
    void on_connected();
    void on_ready_read();
    void on_disconnected();
    void maybe_send(bool periodic, bool force = false);
    void set_status(const QString &s);
    QString station() const;

    bool m_enabled = false;
    QString m_callsign;
    QString m_comment = "DMR Cep";
    QString m_symbol = "/[";
    QTcpSocket *m_socket = nullptr;
    QTimer *m_periodic = nullptr;
    QTimer *m_retry = nullptr;
    int m_retryMs = 30000;
    bool m_loggedIn = false;
    bool m_hasFix = false;
    double m_lat = 0.0;
    double m_lon = 0.0;
    double m_sentLat = 0.0;
    double m_sentLon = 0.0;
    qint64 m_sentMs = 0;
    QString m_status;
};

#endif
