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

#ifndef PHONEGPS_H
#define PHONEGPS_H

#include <QObject>
#include <QString>

// The phone's own position, used as the DMR hotspot location.
// iOS: CoreLocation, "when in use" permission, ~100 m accuracy (cell/Wi-Fi, GPS only if needed).
// Qt Positioning is not part of the iOS Qt kit, so this talks to CoreLocation directly.
// Other platforms: stub that reports "Not available on this platform".
// Lives on the GUI thread; all signals are emitted there.
class PhoneGps : public QObject
{
    Q_OBJECT
public:
    enum State { Off, NeedPermission, Denied, ServicesOff, Waiting, Fix, Unavailable };

    explicit PhoneGps(QObject *parent = nullptr);
    ~PhoneGps();

    void start();
    void stop();
    bool active() const { return m_active; }
    State state() const { return m_state; }
    bool has_fix() const { return m_state == Fix; }
    // Rounded to 4 decimals; valid only when has_fix().
    double latitude() const { return m_lat; }
    double longitude() const { return m_lon; }
    double accuracy() const { return m_accuracy; }
    QString status_text() const;

    // Called by the platform backend (GUI thread).
    void backend_state(State s);
    void backend_position(double lat, double lon, double accuracy);

signals:
    void status_changed();
    void position_changed();

private:
    bool m_active = false;
    State m_state = Off;
    double m_lat = 0.0;
    double m_lon = 0.0;
    double m_accuracy = -1.0;
    void *m_impl = nullptr;   // platform backend (Objective-C object on iOS)
};

#endif
