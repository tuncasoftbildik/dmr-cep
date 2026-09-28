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

// Platform independent part of PhoneGps. The iOS backend (start/stop, ctor/dtor) is in
// phonegps_ios.mm; other platforms get the stub at the bottom of this file.

#include "phonegps.h"
#include "dmrposition.h"
#include <cmath>

QString PhoneGps::status_text() const
{
    switch(m_state){
    case Off:
        return tr("Off");
    case NeedPermission:
        return tr("Waiting for permission");
    case Denied:
        return tr("Location permission denied");
    case ServicesOff:
        return tr("Location services are off");
    case Waiting:
        return tr("Waiting for location");
    case Fix:
        return QString("%1, %2 (±%3 m)").arg(m_lat, 0, 'f', 4).arg(m_lon, 0, 'f', 4).arg(qRound(m_accuracy));
    case Unavailable:
    default:
#if defined(Q_OS_IOS)
        return tr("Location unavailable");
#else
        return tr("Not available on this platform");
#endif
    }
}

void PhoneGps::backend_state(State s)
{
    if(!m_active && (s != Off) && (s != Unavailable)){
        return;   // late callback after stop()
    }
    // A fix stays a fix while CoreLocation reports "authorized" again.
    if((s == Waiting) && (m_state == Fix)){
        return;
    }
    const QString before = status_text();
    m_state = s;
    if(status_text() != before){
        emit status_changed();
    }
}

void PhoneGps::backend_position(double lat, double lon, double accuracy)
{
    if(!m_active || !dmr_coord_valid(lat, lon)){
        return;
    }
    const QString before = status_text();
    const double rlat = dmr_round_coord(lat);
    const double rlon = dmr_round_coord(lon);
    const bool moved = (m_state != Fix) || (rlat != m_lat) || (rlon != m_lon);
    m_lat = rlat;
    m_lon = rlon;
    m_accuracy = accuracy;
    m_state = Fix;
    if(moved){
        emit position_changed();
    }
    if(status_text() != before){
        emit status_changed();
    }
}

#if !defined(Q_OS_IOS)
PhoneGps::PhoneGps(QObject *parent) : QObject(parent) {}
PhoneGps::~PhoneGps() {}

void PhoneGps::start()
{
    m_active = true;
    backend_state(Unavailable);
}

void PhoneGps::stop()
{
    m_active = false;
    backend_state(Off);
}
#endif
