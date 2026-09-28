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

#ifndef DMRPOSITION_H
#define DMRPOSITION_H

// Position fields of the HomeBrew/MMDVM protocol, kept free of Qt so they can be unit tested.
//
// RPTC (config, sent once at login): latitude is an 8 character field, longitude 9,
// written like MMDVMHost/DMRGateway do: sprintf("%08f") / ("%09f") then truncated by %8.8s / %9.9s.
//
// RPTG (home position update while linked): "RPTG" + 4 byte repeater id + "%+08.4f%+09.4f",
// 25 bytes total. This is what DMRGateway sends from GPSD (CDMRNetwork::writeHomePosition),
// and BrandMeister is the network its sample config enables it for ([DMR Network 1] Location=1).

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>

static const unsigned int DMR_RPTG_LENGTH = 25U;

// Round to 4 decimals (~11 m); plenty for a map pin and avoids publishing the exact spot.
inline double dmr_round_coord(double v)
{
    return std::round(v * 10000.0) / 10000.0;
}

inline bool dmr_coord_valid(double lat, double lon)
{
    return std::isfinite(lat) && std::isfinite(lon) && (lat >= -90.0) && (lat <= 90.0) && (lon >= -180.0) && (lon <= 180.0);
}

// lat/lon buffers must hold at least 20 bytes. Only the first 8 (lat) / 9 (lon) characters
// end up in the RPTC packet.
inline void dmr_format_rptc_position(float lat, float lon, char *latitude, char *longitude)
{
    ::snprintf(latitude, 20U, "%08f", lat);
    ::snprintf(longitude, 20U, "%09f", lon);

    // A locale with a decimal comma must not leak into the protocol.
    char *p;
    if((p = ::strchr(latitude, ',')) != NULL){
        *p = '.';
    }
    if((p = ::strchr(longitude, ',')) != NULL){
        *p = '.';
    }
}

// out must hold at least 26 bytes (25 sent + terminating NUL written by snprintf).
inline unsigned int dmr_build_rptg(uint32_t id, double lat, double lon, unsigned char *out)
{
    ::memcpy(out, "RPTG", 4U);
    out[4] = (id >> 24) & 0xff;
    out[5] = (id >> 16) & 0xff;
    out[6] = (id >> 8) & 0xff;
    out[7] = (id >> 0) & 0xff;
    char text[40U];
    ::snprintf(text, sizeof(text), "%+08.4f%+09.4f", lat, lon);
    char *p;
    while((p = ::strchr(text, ',')) != NULL){
        *p = '.';
    }
    ::memcpy(out + 8U, text, 17U);
    out[DMR_RPTG_LENGTH] = 0;
    return DMR_RPTG_LENGTH;
}

// Great-circle distance in metres.
inline double dmr_distance_m(double lat1, double lon1, double lat2, double lon2)
{
    const double r = 6371000.0;
    const double d2r = M_PI / 180.0;
    const double dlat = (lat2 - lat1) * d2r;
    const double dlon = (lon2 - lon1) * d2r;
    const double a = std::sin(dlat / 2) * std::sin(dlat / 2) +
                     std::cos(lat1 * d2r) * std::cos(lat2 * d2r) * std::sin(dlon / 2) * std::sin(dlon / 2);
    return 2.0 * r * std::atan2(std::sqrt(a), std::sqrt(1.0 - a));
}

#endif
