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

#include "aprsbeacon.h"

#include <QDateTime>
#include <QDebug>
#include <QtMath>
#include <cmath>

namespace {
const char *kServer = "rotate.aprs2.net";
const quint16 kPort = 14580;
const char *kSsid = "-7";                 // handheld
const char *kToCall = "APZDMR";           // APZ = experimental software
const char *kSymbol = "/[";               // primary table, person
const char *kComment = "DMR Cep";
const double kMinMoveMeters = 300.0;
const qint64 kMinIntervalMs = 60 * 1000;
const qint64 kMaxIntervalMs = 20 * 60 * 1000;

double distance_m(double lat1, double lon1, double lat2, double lon2)
{
    const double r = 6371000.0;
    const double dlat = qDegreesToRadians(lat2 - lat1);
    const double dlon = qDegreesToRadians(lon2 - lon1);
    const double a = std::sin(dlat / 2) * std::sin(dlat / 2)
                   + std::cos(qDegreesToRadians(lat1)) * std::cos(qDegreesToRadians(lat2))
                   * std::sin(dlon / 2) * std::sin(dlon / 2);
    return 2 * r * std::atan2(std::sqrt(a), std::sqrt(1 - a));
}
}

AprsBeacon::AprsBeacon(QObject *parent) : QObject(parent)
{
    m_periodic = new QTimer(this);
    m_periodic->setInterval(60 * 1000);
    connect(m_periodic, &QTimer::timeout, this, [this]() { maybe_send(true); });

    m_retry = new QTimer(this);
    m_retry->setSingleShot(true);
    connect(m_retry, &QTimer::timeout, this, &AprsBeacon::connect_server);
}

// Standard APRS-IS passcode of the base callsign (no SSID).
int AprsBeacon::passcode(const QString &callsign)
{
    const QByteArray c = callsign.section('-', 0, 0).toUpper().toLatin1();
    int hash = 0x73e2;
    for (int i = 0; i < c.size(); i += 2) {
        hash ^= (uchar)c[i] << 8;
        if (i + 1 < c.size()) hash ^= (uchar)c[i + 1];
    }
    return hash & 0x7fff;
}

// "4101.15N/02840.69E" (symbol table char in the middle is added by the caller).
QString AprsBeacon::format_position(double lat, double lon)
{
    auto part = [](double v, int degWidth, char pos, char neg) {
        const char h = v < 0 ? neg : pos;
        v = std::fabs(v);
        int deg = int(v);
        double min = (v - deg) * 60.0;
        if (min >= 59.995) { deg += 1; min = 0.0; }
        return QString("%1%2%3").arg(deg, degWidth, 10, QChar('0'))
                                .arg(min, 5, 'f', 2, QChar('0'))
                                .arg(QChar(h));
    };
    return part(lat, 2, 'N', 'S') + "|" + part(lon, 3, 'E', 'W');
}

QString AprsBeacon::station() const
{
    return m_callsign.section('-', 0, 0).toUpper() + kSsid;
}

void AprsBeacon::set_callsign(const QString &callsign)
{
    const QString c = callsign.simplified().toUpper();
    if (c == m_callsign) return;
    m_callsign = c;
    if (m_enabled && m_socket) {
        // Log in again under the new callsign.
        m_socket->abort();
    }
}

void AprsBeacon::set_enabled(bool on)
{
    if (on == m_enabled) return;
    m_enabled = on;
    if (on) {
        m_retryMs = 30000;
        m_sentMs = 0;
        m_periodic->start();
        connect_server();
    } else {
        m_periodic->stop();
        m_retry->stop();
        if (m_socket) {
            m_socket->disconnect(this);
            m_socket->abort();
            m_socket->deleteLater();
            m_socket = nullptr;
        }
        m_loggedIn = false;
        set_status(tr("Off"));
    }
}

void AprsBeacon::update_position(double lat, double lon)
{
    m_lat = lat;
    m_lon = lon;
    m_hasFix = true;
    maybe_send(false);
}

void AprsBeacon::connect_server()
{
    if (!m_enabled) return;
    if (m_callsign.isEmpty()) {
        set_status(tr("No callsign set"));
        return;
    }
    if (!m_socket) {
        m_socket = new QTcpSocket(this);
        connect(m_socket, &QTcpSocket::connected, this, &AprsBeacon::on_connected);
        connect(m_socket, &QTcpSocket::readyRead, this, &AprsBeacon::on_ready_read);
        connect(m_socket, &QTcpSocket::disconnected, this, &AprsBeacon::on_disconnected);
        connect(m_socket, &QTcpSocket::errorOccurred, this, [this](QAbstractSocket::SocketError) {
            qDebug() << "APRS: socket error" << (m_socket ? m_socket->errorString() : QString());
            on_disconnected();
        });
    }
    m_loggedIn = false;
    set_status(tr("Connecting to APRS-IS"));
    m_socket->abort();
    m_socket->connectToHost(kServer, kPort);
}

void AprsBeacon::on_connected()
{
    const QString login = QString("user %1 pass %2 vers DMRCep 1.0\r\n")
                              .arg(station()).arg(passcode(m_callsign));
    m_socket->write(login.toLatin1());
    qDebug().noquote() << "APRS: connected, logging in as" << station();
}

void AprsBeacon::on_ready_read()
{
    while (m_socket && m_socket->canReadLine()) {
        const QString line = QString::fromLatin1(m_socket->readLine()).trimmed();
        if (!line.startsWith("# logresp")) continue;   // server keepalives / banner
        qDebug().noquote() << "APRS:" << line;
        if (line.contains(" verified")) {
            m_loggedIn = true;
            m_retryMs = 30000;
            set_status(m_hasFix ? tr("Connected as %1").arg(station())
                                : tr("Connected as %1, waiting for location").arg(station()));
            maybe_send(false);
        } else {
            set_status(tr("APRS-IS rejected the login"));
        }
    }
}

void AprsBeacon::on_disconnected()
{
    m_loggedIn = false;
    if (!m_enabled) return;
    if (!m_retry->isActive()) {
        set_status(tr("APRS-IS connection lost, retrying"));
        m_retry->start(m_retryMs);
        m_retryMs = qMin(m_retryMs * 2, 5 * 60 * 1000);
    }
}

void AprsBeacon::maybe_send(bool periodic)
{
    if (!m_enabled || !m_hasFix) return;
    if (!m_loggedIn || !m_socket) {
        if (m_socket && m_socket->state() == QAbstractSocket::UnconnectedState && !m_retry->isActive())
            connect_server();
        return;
    }
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (m_sentMs != 0) {
        const qint64 since = now - m_sentMs;
        const bool moved = distance_m(m_sentLat, m_sentLon, m_lat, m_lon) >= kMinMoveMeters;
        if (!(moved && since >= kMinIntervalMs) && !(periodic && since >= kMaxIntervalMs))
            return;
    }
    const QString pos = format_position(m_lat, m_lon);
    const QString packet = QString("%1>%2,TCPIP*:!%3%4%5%6%7\r\n")
                               .arg(station(), kToCall,
                                    pos.section('|', 0, 0), QChar(kSymbol[0]),
                                    pos.section('|', 1, 1), QChar(kSymbol[1]), kComment);
    m_socket->write(packet.toLatin1());
    m_sentMs = now;
    m_sentLat = m_lat;
    m_sentLon = m_lon;
    qDebug().noquote() << "APRS: sent" << packet.trimmed();
    set_status(tr("Sent %1 as %2").arg(QDateTime::currentDateTime().toString("HH:mm"), station()));
}

void AprsBeacon::set_status(const QString &s)
{
    if (s == m_status) return;
    m_status = s;
    emit status_changed();
}

QString AprsBeacon::status_text() const
{
    return m_enabled ? m_status : tr("Off");
}
