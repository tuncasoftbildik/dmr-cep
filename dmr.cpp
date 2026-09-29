/*
    Copyright (C) 2019-2021 Doug McLain

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

#include <iostream>
#include <cstring>
#include <QDateTime>
#include <cmath>
#include <QStandardPaths>
#include <QFile>
#include <QDir>
#include "dmr.h"
#include "subtitles.h"
#include "cgolay2087.h"
#include "crs129.h"
#include "SHA256.h"
#include "CRCenc.h"
#include "MMDVMDefines.h"
#include "dmrposition.h"
#ifdef USE_MD380_VOCODER
#include <md380_vocoder.h>
#endif

const uint32_t ENCODING_TABLE_1676[] =
    {0x0000U, 0x0273U, 0x04E5U, 0x0696U, 0x09C9U, 0x0BBAU, 0x0D2CU, 0x0F5FU, 0x11E2U, 0x1391U, 0x1507U, 0x1774U,
     0x182BU, 0x1A58U, 0x1CCEU, 0x1EBDU, 0x21B7U, 0x23C4U, 0x2552U, 0x2721U, 0x287EU, 0x2A0DU, 0x2C9BU, 0x2EE8U,
     0x3055U, 0x3226U, 0x34B0U, 0x36C3U, 0x399CU, 0x3BEFU, 0x3D79U, 0x3F0AU, 0x411EU, 0x436DU, 0x45FBU, 0x4788U,
     0x48D7U, 0x4AA4U, 0x4C32U, 0x4E41U, 0x50FCU, 0x528FU, 0x5419U, 0x566AU, 0x5935U, 0x5B46U, 0x5DD0U, 0x5FA3U,
     0x60A9U, 0x62DAU, 0x644CU, 0x663FU, 0x6960U, 0x6B13U, 0x6D85U, 0x6FF6U, 0x714BU, 0x7338U, 0x75AEU, 0x77DDU,
     0x7882U, 0x7AF1U, 0x7C67U, 0x7E14U, 0x804FU, 0x823CU, 0x84AAU, 0x86D9U, 0x8986U, 0x8BF5U, 0x8D63U, 0x8F10U,
     0x91ADU, 0x93DEU, 0x9548U, 0x973BU, 0x9864U, 0x9A17U, 0x9C81U, 0x9EF2U, 0xA1F8U, 0xA38BU, 0xA51DU, 0xA76EU,
     0xA831U, 0xAA42U, 0xACD4U, 0xAEA7U, 0xB01AU, 0xB269U, 0xB4FFU, 0xB68CU, 0xB9D3U, 0xBBA0U, 0xBD36U, 0xBF45U,
     0xC151U, 0xC322U, 0xC5B4U, 0xC7C7U, 0xC898U, 0xCAEBU, 0xCC7DU, 0xCE0EU, 0xD0B3U, 0xD2C0U, 0xD456U, 0xD625U,
     0xD97AU, 0xDB09U, 0xDD9FU, 0xDFECU, 0xE0E6U, 0xE295U, 0xE403U, 0xE670U, 0xE92FU, 0xEB5CU, 0xEDCAU, 0xEFB9U,
     0xF104U, 0xF377U, 0xF5E1U, 0xF792U, 0xF8CDU, 0xFABEU, 0xFC28U, 0xFE5BU};

DMR::DMR() :
    m_txslot(2),
    m_txcc(1)
{
    m_mode = "DMR";
    m_dmrcnt = 0;
    m_flco = FLCO_GROUP;
    m_attenuation = 5;
#ifdef USE_MD380_VOCODER
    md380_init();
#endif
}

DMR::~DMR()
{
    if (m_subtitle_on) SubtitleTap::end();   // disconnected mid-over: close the caption
}

void DMR::set_dmr_params(uint8_t essid, QString password, QString lat, QString lon, QString location, QString desc, QString freq, QString url, QString swid, QString pkid, QString options)
{
    if (essid){
        m_essid = m_dmrid * 100 + (essid-1);
    }
    else{
        m_essid = m_dmrid;
    }

    m_password = password;
    m_lat = lat;
    m_lon = lon;
    m_location = location;
    m_desc = desc;
    m_freq = freq;
    m_url = url;
    m_swid = swid;
    m_pkid = pkid;
    m_options = options;
}

void DMR::send_position(QString lat, QString lon)
{
    m_lat = lat;
    m_lon = lon;
    if((m_modeinfo.status != CONNECTED_RW) || (m_udp == nullptr)){
        return;   // the next RPTC login carries it
    }
    unsigned char out[DMR_RPTG_LENGTH + 1U];
    const unsigned int len = dmr_build_rptg(m_essid, lat.toDouble(), lon.toDouble(), out);
    m_udp->writeDatagram((const char *)out, len, m_address, m_modeinfo.port);
    m_rptg_sent_ms = QDateTime::currentMSecsSinceEpoch();
    emit update_log("DMR: position update sent (" + lat + ", " + lon + ")");
}

void DMR::set_rx_filter(QString filter)
{
    m_rx_allow.clear();
    m_rx_filter_on = filter.startsWith("on:");
    if(m_rx_filter_on){
        const QStringList tgs = filter.mid(3).split(',', Qt::SkipEmptyParts);
        for(const QString &tg : tgs){
            m_rx_allow.insert(tg.trimmed().toUInt());
        }
    }
    m_rx_muted_stream = 0;
    qDebug() << "DMR RX filter" << (m_rx_filter_on ? filter.mid(3) : QString("off (all talkgroups)"));
}

// Group call to a talkgroup the user does not listen to. Private calls and the talkgroup we
// transmit on always come through.
bool DMR::rx_muted(const QByteArray &buf)
{
    if(!m_rx_filter_on || m_tx){
        return false;
    }
    const uint8_t flags = (uint8_t)buf.data()[15];
    if(flags & 0x40){
        return false;   // private call
    }
    const uint32_t dst = (uint32_t)(((uint8_t)buf.data()[8] << 16) | ((uint8_t)buf.data()[9] << 8) | (uint8_t)buf.data()[10]);
    if((dst == m_txdstid) || m_rx_allow.contains(dst)){
        return false;
    }
    const uint32_t streamid = (uint32_t)(((uint8_t)buf.data()[16] << 24) | ((uint8_t)buf.data()[17] << 16) | ((uint8_t)buf.data()[18] << 8) | (uint8_t)buf.data()[19]);
    if(streamid != m_rx_muted_stream){
        m_rx_muted_stream = streamid;
        const uint32_t src = (uint32_t)(((uint8_t)buf.data()[5] << 16) | ((uint8_t)buf.data()[6] << 8) | (uint8_t)buf.data()[7]);
        qDebug() << "DMR RX muted: stream from" << src << "to TG" << dst;
    }
    return true;
}

void DMR::process_udp()
{
    QByteArray buf;
    QByteArray in;
    QByteArray out;
    QHostAddress sender;
    quint16 senderPort;
    CSHA256 sha256;
    char buffer[400U];

    buf.resize(m_udp->pendingDatagramSize());
    m_udp->readDatagram(buf.data(), buf.size(), &sender, &senderPort);
    m_last_rx_ms = QDateTime::currentMSecsSinceEpoch();

    // While linked, MSTNAK (master forgot us, e.g. after a restart) and MSTCL (master closing)
    // mean the link is dead. Without this the app keeps showing "Connected" with no audio.
    if(buf.size() < 6){
        return;   // nothing valid in the HomeBrew protocol is this short
    }
    if((m_modeinfo.status == CONNECTED_RW) &&
        ((::memcmp(buf.data(), "MSTNAK", 6U) == 0) || (::memcmp(buf.data(), "MSTCL", 5U) == 0))){
        if(m_rptg_sent_ms && (m_last_rx_ms - m_rptg_sent_ms < RPTG_REJECT_WINDOW_MS)){
            // Most likely this master does not know RPTG; the reconnect logs in with RPTC instead.
            emit update_log("DMR: master rejected the position update (RPTG); position will only be sent at login.");
            emit position_update_rejected();
        }
        report_connection_lost(::memcmp(buf.data(), "MSTCL", 5U) == 0 ? "master closed connection (MSTCL)" : "master dropped us (MSTNAK)");
        return;
    }
   

    if(m_debug){
        QDebug debug = qDebug();
        debug.noquote();
        QString s = "RECV:";
        for(int i = 0; i < buf.size(); ++i){
            s += " " + QString("%1").arg((uint8_t)buf.data()[i], 2, 16, QChar('0'));
        }
        debug << s;
    }

    if((m_modeinfo.status != CONNECTED_RW) && (::memcmp(buf.data() + 3, "NAK", 3U) == 0)){
        // NAK during login/config typically indicates auth/config rejection.
        if (m_password.isEmpty()) {
            emit update_log("DMR: login rejected (NAK). Password is empty.");
        } else {
            emit update_log("DMR: login/config rejected (NAK). Check password and DMR profile fields.");
        }
        m_modeinfo.status = DISCONNECTED;
    }
    if((m_modeinfo.status != CONNECTED_RW) && (::memcmp(buf.data(), "MSTCL", 5U) == 0)){
        emit update_log("DMR: master closed connection (MSTCL).");
        m_modeinfo.status = CLOSED;
    }
    if((m_modeinfo.status != CONNECTED_RW) && (::memcmp(buf.data(), "RPTACK", 6U) == 0)){
        switch(m_modeinfo.status){
        case CONNECTING:
            m_modeinfo.status = DMR_AUTH;
            in.append(buf[6]);
            in.append(buf[7]);
            in.append(buf[8]);
            in.append(buf[9]);
            in.append(m_password.toUtf8());

            out.clear();
            out.resize(40);
            out[0] = 'R';
            out[1] = 'P';
            out[2] = 'T';
            out[3] = 'K';
            out[4] = (m_essid >> 24) & 0xff;
            out[5] = (m_essid >> 16) & 0xff;
            out[6] = (m_essid >> 8) & 0xff;
            out[7] = (m_essid >> 0) & 0xff;
            sha256.buffer((uint8_t *)in.data(), (uint32_t)(m_password.size() + sizeof(uint32_t)), (uint8_t *)out.data() + 8U);
            break;
        case DMR_AUTH:
            out.clear();
            buffer[0] = 'R';
            buffer[1] = 'P';
            buffer[2] = 'T';
            buffer[3] = 'C';
            buffer[4] = (m_essid >> 24) & 0xff;
            buffer[5] = (m_essid >> 16) & 0xff;
            buffer[6] = (m_essid >> 8) & 0xff;
            buffer[7] = (m_essid >> 0) & 0xff;

            m_modeinfo.status = DMR_CONF;
            char latitude[20U];
            char longitude[20U];
            dmr_format_rptc_position(m_lat.toFloat(), m_lon.toFloat(), latitude, longitude);
            ::sprintf(buffer + 8U, "%-8.8s%09u%09u%02u%02u%8.8s%9.9s%03d%-20.20s%-19.19s%c%-124.124s%-40.40s%-40.40s", m_modeinfo.callsign.toStdString().c_str(),
                      m_freq.toUInt(), m_freq.toUInt(), 1, 1, latitude, longitude, 0, m_location.toStdString().c_str(), m_desc.toStdString().c_str(), '4',
                      m_url.toStdString().c_str(), m_swid.toStdString().c_str(), m_pkid.toStdString().c_str());
            out.append(buffer, 302);
            break;
        case DMR_CONF:
            setup_connection();
            if(m_options.size()){
                out.clear();
                out.append('R');
                out.append('P');
                out.append('T');
                out.append('O');
                out.append((m_essid >> 24) & 0xff);
                out.append((m_essid >> 16) & 0xff);
                out.append((m_essid >> 8) & 0xff);
                out.append((m_essid >> 0) & 0xff);
                out.append(m_options.toUtf8());
            }
            break;
        case DMR_OPTS:
            //setup_connection();
            break;
        default:
            break;
        }
        if(m_modeinfo.status == CONNECTED_RW){
            if(m_handshake_timer) m_handshake_timer->stop();
            m_udp->writeDatagram(out, m_address, m_modeinfo.port);
        }
        else{
            send_handshake(out);
        }
    }
    if((buf.size() == 11) && (::memcmp(buf.data(), "MSTPONG", 7U) == 0)){
        m_modeinfo.count++;
        lq_pong_received();
    }
    // Talker Alias block relayed by the master in MMDVMHost's "DMRA" format.
    if((buf.size() >= 15) && (::memcmp(buf.data(), "DMRA", 4U) == 0) && !m_tx){
        const uint8_t *d = (const uint8_t *)buf.data();
        const uint32_t id = ((uint32_t)d[4] << 16) | ((uint32_t)d[5] << 8) | d[6];
        if((id == m_modeinfo.srcid) && m_rx_ta.addBlock(d[7], d + 8)){
            rx_talker_alias_update();
        }
    }
    if((buf.size() == 55) && (::memcmp(buf.data(), "DMRD", 4U) == 0) && rx_muted(buf)){
        return;
    }
    if((buf.size() != 55) && ( (m_modeinfo.stream_state == STREAM_LOST) || (m_modeinfo.stream_state == STREAM_END) )){
        m_modeinfo.stream_state = STREAM_IDLE;
    }
    if((buf.size() == 55) &&
        (::memcmp(buf.data(), "DMRD", 4U) == 0) &&
        ((uint8_t)buf.data()[15] & 0x20) &&
        (m_modeinfo.status == CONNECTED_RW))
    {
        m_rxwatchdog = 0;
        lq_track_rx(buf);
        uint8_t t = 0;
        if((uint8_t)buf.data()[15] & 0x02){
            qDebug() << "DMR RX EOT";
            lq_stream_ended();
            m_modeinfo.stream_state = STREAM_END;
            m_modeinfo.ts = QDateTime::currentMSecsSinceEpoch();
            m_modeinfo.streamid = 0;
            t = 0x42;
            emit update(m_modeinfo);
        }
        else if((uint8_t)buf.data()[15] & 0x01){
            m_audio->start_playback();
            if(!m_rxtimer->isActive()){
                m_rxtimer->start(m_rxtimerint);
            }
            m_modeinfo.stream_state = STREAM_NEW;
            m_modeinfo.ts = QDateTime::currentMSecsSinceEpoch();
            m_modeinfo.srcid = (uint32_t)((buf.data()[5] << 16) | ((buf.data()[6] << 8) & 0xff00) | (buf.data()[7] & 0xff));
            m_modeinfo.dstid = (uint32_t)((buf.data()[8] << 16) | ((buf.data()[9] << 8) & 0xff00) | (buf.data()[10] & 0xff));
            m_modeinfo.gwid = (uint32_t)((buf.data()[11] << 24) | ((buf.data()[12] << 16) & 0xff0000) | ((buf.data()[13] << 8) & 0xff00) | (buf.data()[14] & 0xff));
            m_modeinfo.streamid = (uint32_t)((buf.data()[16] << 24) | ((buf.data()[17] << 16) & 0xff0000) | ((buf.data()[18] << 8) & 0xff00) | (buf.data()[19] & 0xff));
            m_modeinfo.frame_number = (uint8_t)buf.data()[4];
            m_modeinfo.slot = (buf.data()[15] & 0x80) ? 2 : 1;
            rx_talker_alias_reset(m_modeinfo.streamid);
            t = 0x41;
            qDebug() << "New DMR stream from " << m_modeinfo.srcid << " to " << m_modeinfo.dstid << "m_tx" << m_tx << "rxtimer" << m_rxtimer->isActive();
            m_rx_frames_in = 0;
            m_rx_frames_decoded = 0;
            emit update(m_modeinfo);
        }
        if(m_modem){
            m_rxmodemq.append(MMDVM_FRAME_START);
            m_rxmodemq.append(0x25);
            m_rxmodemq.append(MMDVM_DMR_DATA2);
            m_rxmodemq.append(t);

            for(int i = 0; i < 33; ++i){
                m_rxmodemq.append(buf.data()[20+i]);
            };
        }
    }
    if((buf.size() == 55) &&
        (::memcmp(buf.data(), "DMRD", 4U) == 0) &&
        !((uint8_t)buf.data()[15] & 0x20) &&
        (m_modeinfo.status == CONNECTED_RW))
    {
        if(!m_tx && ( (m_modeinfo.stream_state == STREAM_LOST) || (m_modeinfo.stream_state == STREAM_END) || (m_modeinfo.stream_state == STREAM_IDLE) )){
            m_audio->start_playback();
            if(!m_rxtimer->isActive()){
                m_rxtimer->start(m_rxtimerint);
            }
            m_modeinfo.stream_state = STREAM_NEW;
        }
        else{
            m_modeinfo.stream_state = STREAMING;
        }
        m_rxwatchdog = 0;
        lq_track_rx(buf);

        uint8_t dmrframe[33];
        uint8_t dmr3ambe[27];
        uint8_t dmrsync[7];
        // get the 33 bytes ambe
        memcpy(dmrframe, &(buf.data()[20]), 33);
        // extract the 3 ambe frames
        memcpy(dmr3ambe, dmrframe, 14);
        dmr3ambe[13] &= 0xF0;
        dmr3ambe[13] |= (dmrframe[19] & 0x0F);
        memcpy(&dmr3ambe[14], &dmrframe[20], 13);
        // extract sync
        dmrsync[0] = dmrframe[13] & 0x0F;
        ::memcpy(&dmrsync[1], &dmrframe[14], 5);
        dmrsync[6] = dmrframe[19] & 0xF0;
        m_modeinfo.srcid =        (uint32_t)((buf.data()[5] << 16) | ((buf.data()[6] << 8) & 0xff00) | (buf.data()[7] & 0xff));
        m_modeinfo.dstid =        (uint32_t)((buf.data()[8] << 16) | ((buf.data()[9] << 8) & 0xff00) | (buf.data()[10] & 0xff));
        m_modeinfo.gwid =        (uint32_t)((buf.data()[11] << 24) | ((buf.data()[12] << 16) & 0xff0000) | ((buf.data()[13] << 8) & 0xff00) | (buf.data()[14] & 0xff));
        m_modeinfo.streamid =    (uint32_t)((buf.data()[16] << 24) | ((buf.data()[17] << 16) & 0xff0000) | ((buf.data()[18] << 8) & 0xff00) | (buf.data()[19] & 0xff));
        m_modeinfo.frame_number = (uint8_t)buf.data()[4];

        if(m_modeinfo.streamid != m_rx_ta_stream){
            rx_talker_alias_reset(m_modeinfo.streamid);  // late entry without a voice header
        }
        rx_embedded_fragment(dmrframe, (uint8_t)buf.data()[15]);

        if(m_modem){
            uint8_t t = ((uint8_t)buf.data()[15] & 0x0f);
            if(!t) t = 0x20;

            m_rxmodemq.append(MMDVM_FRAME_START);
            m_rxmodemq.append(0x25);
            m_rxmodemq.append(MMDVM_DMR_DATA2);
            m_rxmodemq.append(t);

            for(int i = 0; i < 33; ++i){
                m_rxmodemq.append(buf.data()[20+i]);
            }
        }

        for(int i = 0; i < 3; ++i){
            for(int j = 0; j < 9; ++j){
                m_rxcodecq.append(dmr3ambe[j + (9*i)]);
            }
        }
        ++m_rx_frames_in;
        //uint32_t id = (uint32_t)((buf.data()[5] << 16) | ((buf.data()[6] << 8) & 0xff00) | (buf.data()[7] & 0xff));
    }
    emit update(m_modeinfo);

    if(m_debug && out.size() > 0){
        QDebug debug = qDebug();
        debug.noquote();
        QString s = "SEND:";
        for(int i = 0; i < out.size(); ++i){
            s += " " + QString("%1").arg((uint8_t)out.data()[i], 2, 16, QChar('0'));
        }
        debug << s;
    }
}

void DMR::setup_connection()
{
    m_modeinfo.status = CONNECTED_RW;
    m_last_rx_ms = QDateTime::currentMSecsSinceEpoch();
    m_link_lost = false;
    m_lq_ping_pending = false;
    m_lq_rtt_last = -1;
    m_lq_rtt_avg = -1;
    m_lq_ping_hist = 0;
    m_lq_ping_count = 0;
    m_lq_consecutive_miss = 0;
    m_lq_streamid = 0;
    m_lq_last_seq = -1;
    m_lq_rx_received = 0;
    m_lq_rx_lost = 0;
    m_lq_rx_loss_pct = -1;
    m_lq_jitter = 0;
    m_lq_last_frame_ms = 0;
    m_lq_last_emit_ms = 0;
    m_lq_last_log_ms = m_last_rx_ms;
    m_lq_emitted_sig.clear();
    emit link_quality(-1, -1, -1, -1, -1, -1);
    //m_mbeenc->set_gain_adjust(2.5);
    m_modeinfo.sw_vocoder_loaded = load_vocoder_plugin();
    m_txtimer = new QTimer();
    connect(m_txtimer, SIGNAL(timeout()), this, SLOT(transmit()));
    m_rxtimer = new QTimer();
    connect(m_rxtimer, SIGNAL(timeout()), this, SLOT(process_rx_data()));
    m_ping_timer = new QTimer();
    connect(m_ping_timer, SIGNAL(timeout()), this, SLOT(send_ping()));
    m_ping_timer->start(5000);
    m_audio = new AudioEngine(m_audioin, m_audioout);
    m_audio->init();
}

void DMR::hostname_lookup(QHostInfo i)
{
    if (!i.addresses().isEmpty()) {
        QByteArray out;
        out.append('R');
        out.append('P');
        out.append('T');
        out.append('L');
        out.append((m_essid >> 24) & 0xff);
        out.append((m_essid >> 16) & 0xff);
        out.append((m_essid >> 8) & 0xff);
        out.append((m_essid >> 0) & 0xff);
        m_address = i.addresses().first();
        m_udp = new QUdpSocket(this);
        connect(m_udp, SIGNAL(readyRead()), this, SLOT(process_udp()));
        send_handshake(out);

        if(m_debug){
            QDebug debug = qDebug();
            debug.noquote();
            QString s = "CONN:";
            for(int i = 0; i < out.size(); ++i){
                s += " " + QString("%1").arg((uint8_t)out.data()[i], 2, 16, QChar('0'));
            }
            debug << s;
        }
    }
}

// Speech-only AGC + noise gate. The room noise floor is tracked continuously; only blocks
// clearly above it (3x) count as speech and steer the gain (1x..6x, towards -24 dBFS). Blocks
// near the floor are attenuated 12 dB so the vocoder does not encode room hiss as "breath"
// inside words, which is what made the TX sound robotic. Gain and gate are ramped per block.
void DMR::apply_tx_gain(int16_t *pcm, int n)
{
    double acc = 0;
    int peak = 0;
    for(int i = 0; i < n; ++i){ acc += double(pcm[i]) * pcm[i]; peak = qMax(peak, qAbs(int(pcm[i]))); }
    const float rms = float(std::sqrt(acc / n));

    // Noise floor: follow quiet blocks down quickly, creep up slowly otherwise.
    if(rms < m_tx_noise_floor * 1.5f) m_tx_noise_floor += (rms - m_tx_noise_floor) * 0.05f;
    else m_tx_noise_floor *= 1.002f;
    m_tx_noise_floor = qBound(20.0f, m_tx_noise_floor, 4000.0f);

    const bool speech = rms > qMax(m_tx_noise_floor * 3.0f, 250.0f);
    if(speech){
        const float target = qBound(1.0f, 2067.0f / rms, 6.0f);   // -24 dBFS
        m_tx_gain += (target - m_tx_gain) * (target < m_tx_gain ? 0.3f : 0.05f);
    }
    const float gate_target = speech ? 1.0f : 0.25f;
    const float gate_prev = m_tx_gate;
    m_tx_gate += (gate_target - m_tx_gate) * (speech ? 0.6f : 0.15f);   // fast open, slow close

    float g = m_tx_gain;
    if(peak * g > 20000.0f) g = 20000.0f / float(qMax(peak, 1));
    static float last_g = 2.0f;
    for(int i = 0; i < n; ++i){
        const float f = float(i + 1) / float(n);
        const float gi = (last_g + (g - last_g) * f) * (gate_prev + (m_tx_gate - gate_prev) * f);
        pcm[i] = int16_t(qBound(-32767.0f, pcm[i] * gi, 32767.0f));
    }
    last_g = g;
}

// RX AGC towards ~-14 dBFS (2x..32x), ramped per block, then a tanh soft limiter so loud
// stations do not crackle. Quiet blocks (pauses) keep the current gain.
void DMR::apply_rx_gain(int16_t *pcm, int n)
{
    double acc = 0;
    for(int i = 0; i < n; ++i) acc += double(pcm[i]) * pcm[i];
    const double rms = std::sqrt(acc / n);
    if(rms > 60.0){
        const float target = qBound(2.0f, float(6540.0 / rms), 32.0f);   // -14 dBFS
        m_rx_gain += (target - m_rx_gain) * (target < m_rx_gain ? 0.3f : 0.08f);
    }
    for(int i = 0; i < n; ++i){
        const float gi = m_rx_last_gain + (m_rx_gain - m_rx_last_gain) * float(i + 1) / float(n);
        const float x = pcm[i] * gi / 32768.0f;
        pcm[i] = int16_t(std::tanh(x) * 31000.0f);
    }
    m_rx_last_gain = m_rx_gain;
}

static DMR::Bq make_bq(double b0, double b1, double b2, double a0, double a1, double a2)
{
    DMR::Bq q;
    q.b0 = float(b0 / a0); q.b1 = float(b1 / a0); q.b2 = float(b2 / a0);
    q.a1 = float(a1 / a0); q.a2 = float(a2 / a0);
    return q;
}

void DMR::tx_shape(int16_t *pcm, int n)
{
    if(!m_tx_filters_ready || m_tx_tone_changed){
        const double fs = 8000.0;
        // 4th-order high-pass (two RBJ biquads, Butterworth Q values). Corner from the tone setting:
        // natural 120 Hz keeps the chest of the voice, thin 300 Hz is telephone-like, 500 Hz very thin.
        const double fc = (m_tx_tone == 0) ? 120.0 : (m_tx_tone == 2 ? 500.0 : 300.0);
        const double qs[2] = {0.5412, 1.3066};
        Bq *hp[2] = {&m_tx_hpf, &m_tx_hpf2};
        for(int k = 0; k < 2; ++k){
            const double w = 2 * M_PI * fc / fs, al = std::sin(w) / (2 * qs[k]), c = std::cos(w);
            *hp[k] = make_bq((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al);
        }
        // RBJ peaking EQ, 2200 Hz, Q 0.9, +3 dB presence
        const double A = std::pow(10.0, 3.0 / 40.0);
        const double w = 2 * M_PI * 2200.0 / fs, al = std::sin(w) / (2 * 0.9), c = std::cos(w);
        m_tx_peq = make_bq(1 + al * A, -2 * c, 1 - al * A, 1 + al / A, -2 * c, 1 - al / A);
        m_tx_filters_ready = true;
        m_tx_tone_changed = false;
        qDebug() << "TX tone filter:" << fc << "Hz high-pass";
    }
    for(int i = 0; i < n; ++i){
        float x = pcm[i];
        for(Bq *q : {&m_tx_hpf, &m_tx_hpf2, &m_tx_peq}){
            const float y = q->b0 * x + q->z1;
            q->z1 = q->b1 * x - q->a1 * y + q->z2;
            q->z2 = q->b2 * x - q->a2 * y;
            x = y;
        }
        pcm[i] = int16_t(qBound(-32767.0f, x, 32767.0f));
    }
}

static void write_wav_8k(const QString &path, const QByteArray &pcm)
{
    QFile f(path);
    if(!f.open(QIODevice::WriteOnly)) return;
    QByteArray h;
    auto le32 = [&h](quint32 v){ for(int i = 0; i < 4; ++i) h.append(char((v >> (8 * i)) & 0xff)); };
    auto le16 = [&h](quint16 v){ h.append(char(v & 0xff)); h.append(char(v >> 8)); };
    h.append("RIFF"); le32(36 + pcm.size()); h.append("WAVE");
    h.append("fmt "); le32(16); le16(1); le16(1); le32(8000); le32(16000); le16(2); le16(16);
    h.append("data"); le32(pcm.size());
    f.write(h);
    f.write(pcm);
}

static double rms_dbfs(const QByteArray &pcm)
{
    const int16_t *s = reinterpret_cast<const int16_t *>(pcm.constData());
    const int n = pcm.size() / 2;
    if(n == 0) return -120.0;
    double acc = 0;
    for(int i = 0; i < n; ++i) acc += double(s[i]) * s[i];
    return 20.0 * std::log10(std::sqrt(acc / n) / 32768.0 + 1e-9);
}

void DMR::save_tx_debug_audio()
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dir);
    write_wav_8k(dir + "/tx_last_mic.wav", m_tx_mic_pcm);
    write_wav_8k(dir + "/tx_last_decoded.wav", m_tx_loop_pcm);
    qDebug() << "DMR TX audio saved:" << m_tx_mic_pcm.size() / 16000.0 << "s, mic RMS"
             << rms_dbfs(m_tx_mic_pcm) << "dBFS, decoded RMS" << rms_dbfs(m_tx_loop_pcm) << "dBFS";
    // Also keep it in the replay list: what the other side heard (vocoder round trip, tones included).
    const QString path = RxRecorder::writeRecording(m_dmrid, m_txdstid, m_tx_start_ms, m_tx_loop_pcm);
    if (!path.isEmpty()) emit recording_saved(path);
}

void DMR::send_handshake(const QByteArray &out)
{
    m_last_handshake = out;
    m_handshake_resends = 0;
    m_udp->writeDatagram(out, m_address, m_modeinfo.port);
    if(!m_handshake_timer){
        m_handshake_timer = new QTimer(this);
        connect(m_handshake_timer, SIGNAL(timeout()), this, SLOT(resend_handshake()));
    }
    m_handshake_timer->start(HANDSHAKE_RESEND_MS);
}

void DMR::resend_handshake()
{
    const bool handshaking = (m_modeinfo.status == CONNECTING) || (m_modeinfo.status == DMR_AUTH) || (m_modeinfo.status == DMR_CONF);
    if(!handshaking || !m_udp || m_last_handshake.isEmpty() || (m_handshake_resends >= HANDSHAKE_MAX_RESENDS)){
        m_handshake_timer->stop();
        return;
    }
    m_handshake_resends++;
    qDebug() << "DMR: no reply, resending handshake packet" << m_last_handshake.left(4) << "attempt" << m_handshake_resends;
    m_udp->writeDatagram(m_last_handshake, m_address, m_modeinfo.port);
}

void DMR::report_connection_lost(const QString &reason)
{
    if(m_link_lost) return;
    m_link_lost = true;
    if(m_ping_timer) m_ping_timer->stop();
    lq_emit(true);   // bars drop to 0
    emit update_log("DMR: link lost: " + reason);
    emit connection_lost(reason);
}

void DMR::send_ping()
{
    // No MSTPONG/traffic for RX_WATCHDOG_MS: the UDP path is dead (Wi-Fi <-> cellular switch,
    // NAT timeout, server gone). BM answers every 5 s ping, so this is 4 missed pongs.
    if((m_modeinfo.status == CONNECTED_RW) && (m_last_rx_ms > 0) &&
        (QDateTime::currentMSecsSinceEpoch() - m_last_rx_ms > RX_WATCHDOG_MS)){
        report_connection_lost("no reply from server for " + QString::number(RX_WATCHDOG_MS / 1000) + " s");
        return;
    }
    lq_ping_sent();
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if(now - m_lq_last_log_ms >= LQ_LOG_INTERVAL_MS){
        m_lq_last_log_ms = now;
        qDebug().noquote() << "DMR link quality: bars" << lq_bars()
                           << "rtt" << m_lq_rtt_last << "ms avg" << qRound(m_lq_rtt_avg) << "ms"
                           << "ping loss" << lq_ping_loss_pct() << "% (" << m_lq_ping_count << "pings, miss streak" << m_lq_consecutive_miss << ")"
                           << "last RX loss" << m_lq_rx_loss_pct << "% jitter" << qRound(m_lq_jitter) << "ms";
    }
    QByteArray out;
    char tag[] = { 'R','P','T','P','I','N','G' };
    out.append(tag, 7);
    out.append((m_essid >> 24) & 0xff);
    out.append((m_essid >> 16) & 0xff);
    out.append((m_essid >> 8) & 0xff);
    out.append((m_essid >> 0) & 0xff);
    m_udp->writeDatagram(out, m_address, m_modeinfo.port);

    if(m_debug){
        QDebug debug = qDebug();
        debug.noquote();
        QString s = "PING:";
        for(int i = 0; i < out.size(); ++i){
            s += " " + QString("%1").arg((uint8_t)out.data()[i], 2, 16, QChar('0'));
        }
        debug << s;
    }
}

// ---- Link quality ------------------------------------------------------------------------

void DMR::lq_ping_sent()
{
    if(m_lq_ping_pending){
        // The previous ping got no MSTPONG before this one: count it as lost.
        m_lq_ping_hist = quint16(((m_lq_ping_hist << 1) | 1U) & ((1U << LQ_PING_WINDOW) - 1U));
        m_lq_ping_count = qMin(m_lq_ping_count + 1, LQ_PING_WINDOW);
        m_lq_consecutive_miss++;
    }
    m_lq_ping_pending = true;
    m_lq_ping_clock.start();
    lq_emit(true);
}

void DMR::lq_pong_received()
{
    if(!m_lq_ping_pending) return;   // late pong of a ping already counted as lost
    m_lq_ping_pending = false;
    m_lq_rtt_last = int(m_lq_ping_clock.elapsed());
    m_lq_rtt_avg = (m_lq_rtt_avg < 0) ? m_lq_rtt_last : (0.75 * m_lq_rtt_avg + 0.25 * m_lq_rtt_last);
    m_lq_ping_hist = quint16((m_lq_ping_hist << 1) & ((1U << LQ_PING_WINDOW) - 1U));
    m_lq_ping_count = qMin(m_lq_ping_count + 1, LQ_PING_WINDOW);
    m_lq_consecutive_miss = 0;
    lq_emit(true);
}

// Called for every DMRD frame while linked. The sequence byte (buf[4]) counts up by one per
// packet within a stream, so a jump of n means n - 1 packets never arrived.
void DMR::lq_track_rx(const QByteArray &buf)
{
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const uint8_t flags = (uint8_t)buf.data()[15];
    const bool data_sync = flags & 0x20;
    const bool lc_header = data_sync && ((flags & 0x0f) == 0x01);
    const uint32_t sid = ((uint8_t)buf.data()[16] << 24) | ((uint8_t)buf.data()[17] << 16) | ((uint8_t)buf.data()[18] << 8) | (uint8_t)buf.data()[19];
    const int seq = (uint8_t)buf.data()[4];

    if(sid != m_lq_streamid){
        // Another stream interleaving with a live one (other slot): keep measuring the live one.
        if(!lc_header && m_lq_streamid && (now - m_lq_last_frame_ms < 1000)) return;
        m_lq_streamid = sid;
        m_lq_last_seq = seq;
        m_lq_rx_received = 1;
        m_lq_rx_lost = 0;
        m_lq_rx_loss_pct = 0;
        m_lq_jitter = 0;
        m_lq_last_frame_ms = now;
        m_lq_prev_voice = !data_sync;
        lq_emit(false);
        return;
    }
    const int diff = (seq - m_lq_last_seq) & 0xff;
    if(diff == 0) return;   // duplicate
    if(diff < 128){
        m_lq_rx_lost += diff - 1;
        if(!data_sync && m_lq_prev_voice){
            // Voice packets carry 60 ms of audio each; deviation from that is jitter.
            const double d = double(now - m_lq_last_frame_ms) - 60.0 * diff;
            m_lq_jitter += (std::fabs(d) - m_lq_jitter) / 16.0;
        }
        m_lq_last_seq = seq;
        m_lq_last_frame_ms = now;
        m_lq_prev_voice = !data_sync;
    }
    else if(m_lq_rx_lost > 0){
        m_lq_rx_lost--;   // out of order: it was counted as lost when the gap opened
    }
    m_lq_rx_received++;
    m_lq_rx_loss_pct = qRound(100.0 * m_lq_rx_lost / (m_lq_rx_received + m_lq_rx_lost));
    lq_emit(false);
}

void DMR::lq_stream_ended()
{
    if(m_lq_streamid && (m_lq_rx_received + m_lq_rx_lost) > 0){
        qDebug() << "DMR RX stream quality: received" << m_lq_rx_received << "lost" << m_lq_rx_lost
                 << "(" << m_lq_rx_loss_pct << "%) jitter" << qRound(m_lq_jitter) << "ms";
    }
    m_lq_streamid = 0;
    lq_emit(true);
}

int DMR::lq_ping_loss_pct() const
{
    if(m_lq_ping_count == 0) return -1;
    const quint16 mask = quint16((1U << m_lq_ping_count) - 1U);
    return qRound(100.0 * qPopulationCount(quint16(m_lq_ping_hist & mask)) / m_lq_ping_count);
}

// 4 = RTT < 150 ms, no ping loss, RX loss < 1 %
// 3 = RTT < 300 ms, ping loss <= 10 %, RX loss < 3 %
// 2 = RTT < 600 ms, ping loss <= 20 %, RX loss < 8 %
// 1 = still answering, but worse than that
// 0 = link lost, or 2+ pings in a row without a pong
// RX loss only counts while a stream is live or up to 2 min after it (and only with >= 10 frames).
int DMR::lq_bars() const
{
    if(m_link_lost || (m_lq_consecutive_miss >= 2)) return 0;
    if(m_lq_rtt_avg < 0) return -1;
    const int ploss = qMax(0, lq_ping_loss_pct());
    int rx = 0;
    if((m_lq_rx_loss_pct >= 0) && ((m_lq_rx_received + m_lq_rx_lost) >= 10) &&
        (QDateTime::currentMSecsSinceEpoch() - m_lq_last_frame_ms < LQ_RX_LOSS_RELEVANT_MS)){
        rx = m_lq_rx_loss_pct;
    }
    const double rtt = m_lq_rtt_avg;
    if((rtt < 150) && (ploss == 0) && (rx < 1)) return 4;
    if((rtt < 300) && (ploss <= 10) && (rx < 3)) return 3;
    if((rtt < 600) && (ploss <= 20) && (rx < 8)) return 2;
    return 1;
}

void DMR::lq_emit(bool force)
{
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if(!force && (now - m_lq_last_emit_ms < LQ_EMIT_MIN_MS)) return;
    const int bars = lq_bars();
    const int avg = (m_lq_rtt_avg < 0) ? -1 : qRound(m_lq_rtt_avg);
    const int ploss = lq_ping_loss_pct();
    const int jitter = (m_lq_rx_loss_pct < 0) ? -1 : qRound(m_lq_jitter);
    const QString sig = QString("%1/%2/%3/%4/%5/%6").arg(bars).arg(m_lq_rtt_last).arg(avg).arg(ploss).arg(m_lq_rx_loss_pct).arg(jitter);
    if(sig == m_lq_emitted_sig) return;
    // A burst of forced updates (ping + pong + end of stream) is still at most a few per second.
    m_lq_emitted_sig = sig;
    m_lq_last_emit_ms = now;
    emit link_quality(bars, m_lq_rtt_last, avg, ploss, m_lq_rx_loss_pct, jitter);
}

void DMR::send_disconnect()
{
    QByteArray out;
    out.append('R');
    out.append('P');
    out.append('T');
    out.append('C');
    out.append('L');
    out.append((m_essid >> 24) & 0xff);
    out.append((m_essid >> 16) & 0xff);
    out.append((m_essid >> 8) & 0xff);
    out.append((m_essid >> 0) & 0xff);
    m_udp->writeDatagram(out, m_address, m_modeinfo.port);

    if(m_debug){
        QDebug debug = qDebug();
        debug.noquote();
        QString s = "SEND:";
        for(int i = 0; i < out.size(); ++i){
            s += " " + QString("%1").arg((uint8_t)out.data()[i], 2, 16, QChar('0'));
        }
        debug << s;
    }
}

void DMR::process_modem_data(QByteArray d)
{
    QByteArray txdata;
    uint8_t lcData[12U];

    uint8_t *p_frame = (uint8_t *)(d.data());
    m_dataType = p_frame[3U] & 0x0f;

    if ((p_frame[3U] & DMR_SYNC_DATA) == DMR_SYNC_DATA){
        if((m_dataType == DT_VOICE_LC_HEADER) && (m_modeinfo.stream_state == STREAM_IDLE)){
            m_modeinfo.stream_state = TRANSMITTING_MODEM;
        }
        else if(m_dataType == DT_TERMINATOR_WITH_LC){
            m_modeinfo.stream_state = STREAM_IDLE;
        }

        m_dmrcnt = 0;
        m_bptc.decode(p_frame + 4, lcData);
        m_txdstid = lcData[3U] << 16 | lcData[4U] << 8 | lcData[5U];
        m_txsrcid = lcData[6U] << 16 | lcData[7U] << 8 | lcData[8U];
        m_flco = FLCO(lcData[0U] & 0x3FU);
        build_frame();
        ::memcpy(m_dmrFrame + 20U, p_frame + 4, 33U);
        txdata.append((char *)m_dmrFrame, 55);
        m_udp->writeDatagram(txdata, m_address, m_modeinfo.port);
    }
    else {
        m_dataType = (m_dmrcnt % 6U) ? DT_VOICE : DT_VOICE_SYNC;
        build_frame();
        ::memcpy(m_dmrFrame + 20U, p_frame + 4, 33U);
        txdata.append((char *)m_dmrFrame, 55);
        m_udp->writeDatagram(txdata, m_address, m_modeinfo.port);
        ++m_dmrcnt;
    }

    if(m_debug){
        QDebug debug = qDebug();
        debug.noquote();
        QString s = "SEND:";
        for(int i = 0; i < txdata.size(); ++i){
            s += " " + QString("%1").arg((uint8_t)txdata.data()[i], 2, 16, QChar('0'));
        }
        debug << s;
    }
}

// Roger tones are sent as AMBE+2 tone frames (clean on DVSI radios; the software vocoder
// detuned plain tones by up to 10%). One entry per 20 ms frame: tone index (f = index * 31.25 Hz)
// or 0 for a silent frame.
//   start:  mode 2 = 1188 Hz chirp (80 ms), mode 3 = ZVEI-1 five-tone ANI of our ID,
//           mode 4 = CCIR five-tone "2 1 2 6 5" (the Turkish police radio call-up sound)
//   end:    mode 1/2 = 1000 -> 1500 Hz two-tone, mode 3 = 1000 -> 1500 -> 2000 Hz rising three-tone,
//           mode 4 = CCIR five-tone "1 8 2 7 5"
QVector<int> DMR::roger_head_frames() const
{
    if(m_roger_beep == 2) return QVector<int>(4, 38);
    if(m_roger_beep == 3) return build_ani();
    if(m_roger_beep == 4) return build_ccir("21265");
    return QVector<int>();
}

QVector<int> DMR::roger_tail_frames() const
{
    QVector<int> f;
    if(m_roger_beep == 4){
        f += build_ccir("18275");            // a second police call-up melody, so start and end differ
    }
    else if(m_roger_beep == 3){
        f += QVector<int>(3, 32);
        f += QVector<int>(3, 48);
        f += QVector<int>(3, 64);
    }
    else{
        f += QVector<int>(5, 32);
        f += QVector<int>(6, 48);
    }
    return f;
}

// ZVEI-1 five-tone ANI of the last five digits of our DMR ID. Tone indices on the AMBE 31.25 Hz
// grid (all within 1% of ZVEI-1). A digit equal to the previous one is sent as the repeat tone.
// 70 ms per tone is 3.5 AMBE frames, so the tones alternate 4/3 frames (350 ms in total).
QVector<int> DMR::build_ani() const
{
    static const int zvei[10] = {77, 34, 37, 41, 45, 49, 53, 59, 64, 70};   // 0..9
    static const int repeat_tone = 83;                                         // 2600 Hz
    QString d = QString::number(m_dmrid).right(5).rightJustified(5, '0');
    QVector<int> frames;
    int prev = -1;
    for(int i = 0; i < 5; ++i){
        const int digit = d.at(i).digitValue();
        const int id = (digit == prev) ? repeat_tone : zvei[digit];
        prev = (digit == prev) ? -1 : digit;
        for(int k = 0; k < ((i % 2 == 0) ? 4 : 3); ++k) frames.append(id);
    }
    return frames;
}

// CCIR selective-call five-tone, played one whole tone (2 semitones) below CCIR for a deeper
// sound: CCIR 1981, 1124, 1197, 1275, 1358, 1446, 1540, 1640, 1747, 1860, R 2110 Hz, each x 0.891
// and rounded to the 31.25 Hz grid. No longer decodable as CCIR selcall; the melody is the point.
// Tone lengths in 20 ms AMBE frames: 200, 80, 100, 80, 80 ms (the police-set rhythm; 90 ms is
// not a whole frame, so the third tone is 100 ms).
QVector<int> DMR::build_ccir(const QString &digits) const
{
    static const int ccir[10] = {56, 32, 34, 37, 38, 41, 44, 46, 50, 53};   // 0..9
    static const int repeat_tone = 61;                                      // 1906 Hz
    static const int tone_frames[5] = {10, 4, 5, 4, 4};
    QVector<int> frames;
    int prev = -1;
    int pos = 0;
    for(const QChar c : digits){
        const int digit = c.digitValue();
        if(digit < 0) continue;
        const int id = (digit == prev) ? repeat_tone : ccir[digit];
        prev = (digit == prev) ? -1 : digit;
        const int n = (pos < 5) ? tone_frames[pos] : 4;
        for(int k = 0; k < n; ++k) frames.append(id);
        ++pos;
    }
    return frames;
}

void DMR::transmit()
{
    uint8_t ambe[72];
    int16_t pcm[160];
    bool synth = false;
    int tone_frame = -1;     // >0: send this AMBE tone index instead of encoding pcm

#ifdef USE_FLITE
    if(m_ttsid > 0){
        for(int i = 0; i < 160; ++i){
            if(m_ttscnt >= tts_audio->num_samples/2){
                pcm[i] = 0;
            }
            else{
                pcm[i] = tts_audio->samples[m_ttscnt*2] / 8;
                m_ttscnt++;
            }
        }
    }
#endif
    if(m_tx && !m_tx_logged){
        m_tx_logged = true;
        m_tx_mic_pcm.clear();
        m_tx_loop_pcm.clear();
        m_tx_start_ms = QDateTime::currentMSecsSinceEpoch();
        m_tx_frames = 0;
        m_tx_starved = 0;
        m_tx_peak = 0;
        m_tx_mic_restarted = false;
        qDebug() << "DMR TX start: src" << m_dmrid << "dst" << m_txdstid << (m_flco == FLCO_USER_USER ? "private" : "group") << "slot" << m_txslot << "roger" << m_roger_beep;
        m_roger_tail_started = false;
        m_ani_head = roger_head_frames();
    }

    // Released: keep the stream open until the roger tail has gone out, then fall through to EOT.
    if(!m_tx && m_tx_logged && (m_roger_beep >= 1) && !m_roger_tail_started){
        m_roger_tail_started = true;
        m_ani_tail = QVector<int>() << 0 << 0;           // 40 ms gap after the last word
        m_ani_tail += roger_tail_frames();
        m_ani_tail << 0;
        m_tx = true;
    }
    if(m_tx && m_roger_tail_started){
        if(!m_ani_tail.isEmpty()){
            tone_frame = m_ani_tail.takeFirst();
            memset(pcm, 0, sizeof(pcm));
            int16_t drop[160];
            m_audio->read(drop, 160);
            synth = true;
        }
        else{
            m_tx = false;
        }
    }
    if(m_ttsid == 0 && !synth){
        if(m_audio->read(pcm, 160)){
            if(m_audio->level() > m_tx_peak) m_tx_peak = m_audio->level();
            tx_shape(pcm, 160);
            apply_tx_gain(pcm, 160);
            // Key-up tones (chirp or 5-tone ANI) replace the first frames of mic audio.
            if(!m_ani_head.isEmpty()){
                tone_frame = m_ani_head.takeFirst();
                memset(pcm, 0, sizeof(pcm));
            }
        }
        else if(!m_tx){
            // Released while the mic had nothing buffered: still close the stream with an EOT.
            send_frame();
            return;
        }
        else{
            // No microphone data. Only if the mic has delivered nothing at all for ~0.6 s reopen it
            // once; restarting a working mic mid-sentence caused an audible pop.
            if((++m_tx_starved >= 30) && !m_tx_mic_restarted && (m_audio->captured_bytes() == 0)){
                m_tx_mic_restarted = true;
                qDebug() << "DMR TX: microphone delivered" << m_audio->captured_bytes() << "bytes, restarting capture";
                m_audio->stop_capture();
                m_audio->start_capture();
            }
            return;
        }
    }

    if(m_hwtx){
#if !defined(Q_OS_IOS)
        m_ambedev->encode(pcm);
#endif
    }
    else{
        if(m_modeinfo.sw_vocoder_loaded){
#ifdef USE_MD380_VOCODER
            md380_encode_fec(ambe, pcm);
#else
#ifndef VOCODER_PLUGIN
            if(tone_frame > 0) m_mbevocoder->encode_tone_2450x1150(tone_frame, 90, ambe);
            else
#endif
            m_mbevocoder->encode_2450x1150(pcm, ambe);
#endif
        }
        if(m_tx && m_modeinfo.sw_vocoder_loaded && (m_tx_mic_pcm.size() < 8000 * 2 * 60)){
            m_tx_mic_pcm.append(reinterpret_cast<const char *>(pcm), 160 * 2);
#if !defined(VOCODER_PLUGIN) && !defined(USE_MD380_VOCODER)
            if(!m_tx_loop_vocoder) m_tx_loop_vocoder = new VocoderPlugin();
            int16_t loop[160];
            m_tx_loop_vocoder->decode_2450x1150(loop, ambe);
            m_tx_loop_pcm.append(reinterpret_cast<const char *>(loop), 160 * 2);
#endif
        }
        for(int i = 0; i < 9; ++i){
            m_txcodecq.append(ambe[i]);
        }
    }

    if(m_tx && (m_txcodecq.size() >= 27)){
        for(int i = 0; i < 27; ++i){
            m_ambe[i] = m_txcodecq.dequeue();
        }
        send_frame();
    }
    else if(m_tx == false){
        send_frame();
    }
}

void DMR::send_frame()
{
    QByteArray txdata;

    m_txsrcid = m_dmrid;
    if(m_tx){
        m_modeinfo.stream_state = TRANSMITTING;
        m_modeinfo.slot = m_txslot;

        if(!m_dmrcnt){
            encode_header(DT_VOICE_LC_HEADER);
            m_txstreamid = static_cast<uint32_t>(::rand());
            prepare_talker_alias();
        }
        else{
            ::memcpy(m_dmrFrame + 20U, m_ambe, 13U);
            m_dmrFrame[33U] = m_ambe[13U] & 0xF0U;
            m_dmrFrame[39U] = m_ambe[13U] & 0x0FU;
            ::memcpy(m_dmrFrame + 40U, &m_ambe[14U], 13U);
            encode_data();
        }

        build_frame();
        txdata.append((char *)m_dmrFrame, 55);
        m_udp->writeDatagram(txdata, m_address, m_modeinfo.port);
        ++m_dmrcnt;
        ++m_tx_frames;
/*
        if(!m_dmrcnt){
            for (int i = 0U; i < 3; i++) {
                m_dmrFrame[4U] = m_dmrcnt;
                txdata.append((char *)m_dmrFrame, 55);
                m_udp->writeDatagram(txdata, m_address, m_modeinfo.port);
                m_dmrcnt++;
            }

        }
        else{
            ++m_dmrcnt;
            txdata.append((char *)m_dmrFrame, 55);
            m_udp->writeDatagram(txdata, m_address, m_modeinfo.port);
        }
*/
    }
    else{
        qDebug() << "DMR TX end: voice frames" << m_tx_frames << "mic starved ticks" << m_tx_starved
                 << "mic bytes" << m_audio->captured_bytes() << "peak level" << m_tx_peak;
        m_tx_logged = false;
        m_roger_tail_started = false;
        save_tx_debug_audio();
        get_eot();
        build_frame();
        m_ttscnt = 0;
        txdata.append((char *)m_dmrFrame, 55);
        m_udp->writeDatagram(txdata, m_address, m_modeinfo.port);
        m_txtimer->stop();

        if(m_ttsid == 0){
            m_audio->stop_capture();
        }

        m_modeinfo.stream_state = STREAM_IDLE;
    }
    emit update_output_level(m_audio->level() * 8);
    emit update(m_modeinfo);

    if(m_debug){
        QDebug debug = qDebug();
        debug.noquote();
        QString s = "SEND:";
        for(int i = 0; i < txdata.size(); ++i){
            s += " " + QString("%1").arg((uint8_t)txdata.data()[i], 2, 16, QChar('0'));
        }
        debug << s;
    }
}

uint8_t * DMR::get_eot()
{
    encode_header(DT_TERMINATOR_WITH_LC);
    m_dmrcnt = 0;
    return m_dmrFrame;
}

void DMR::build_frame()
{
    //qDebug() << "DMR: slot:cc:flco == " << m_txslot << ":" << m_txcc << ":" << m_flco;
    m_dmrFrame[0U]  = 'D';
    m_dmrFrame[1U]  = 'M';
    m_dmrFrame[2U]  = 'R';
    m_dmrFrame[3U]  = 'D';

    m_dmrFrame[5U]  = m_txsrcid >> 16;
    m_dmrFrame[6U]  = m_txsrcid >> 8;
    m_dmrFrame[7U]  = m_txsrcid >> 0;
    m_dmrFrame[8U]  = m_txdstid >> 16;
    m_dmrFrame[9U]  = m_txdstid >> 8;
    m_dmrFrame[10U] = m_txdstid >> 0;
    m_dmrFrame[11U]  = m_essid >> 24;
    m_dmrFrame[12U]  = m_essid >> 16;
    m_dmrFrame[13U]  = m_essid >> 8;
    m_dmrFrame[14U]  = m_essid >> 0;

    m_dmrFrame[15U] = (m_txslot == 1U) ? 0x00U : 0x80U;
    m_dmrFrame[15U] |= (m_flco == FLCO_GROUP) ? 0x00U : 0x40U;

    if (m_dataType == DT_VOICE_SYNC) {
        m_dmrFrame[15U] |= 0x10U;
    } else if (m_dataType == DT_VOICE) {
        m_dmrFrame[15U] |= ((m_dmrcnt - 1) % 6U);
    } else {
        m_dmrFrame[15U] |= (0x20U | m_dataType);
    }

    m_dmrFrame[4U] = m_dmrcnt;
    ::memcpy(m_dmrFrame + 16U, &m_txstreamid, 4U);

    m_dmrFrame[53U] = 0; //data.getBER();
    m_dmrFrame[54U] = 0; //data.getRSSI();

    m_modeinfo.srcid = m_txsrcid;
    m_modeinfo.dstid = m_txdstid;
    m_modeinfo.gwid = m_essid;
    m_modeinfo.frame_number = m_dmrcnt;
}

void DMR::encode_header(uint8_t t)
{
    addDMRDataSync(m_dmrFrame+20, 0);
    m_dataType = t;
    full_lc_encode(m_dmrFrame+20, t);
}

void DMR::encode_data()
{
    uint32_t n_dmr = (m_dmrcnt - 1) % 6U;

    if (!n_dmr) {
        m_dataType = DT_VOICE_SYNC;
        addDMRAudioSync(m_dmrFrame+20, 0);
        // Embedded LC rotation: even superframes carry the voice LC (late entry keeps working),
        // odd ones carry the Talker Alias header/blocks in turn: LC, TA0, LC, TA1, LC, TA2, ...
        const uint32_t superframe = (m_dmrcnt - 1) / 6U;
        if (m_ta_blocks && (superframe & 1U)) {
            const unsigned int block = (superframe / 2U) % m_ta_blocks;
            encode_embedded_data(m_ta_lc[block]);
            send_talker_alias_block(block);
        }
        else {
            uint8_t lc[9U];
            ::memset(lc, 0, sizeof(lc));
            lc_get_data(lc);
            encode_embedded_data(lc);
        }
    }
    else {
        m_dataType = DT_VOICE;
        uint8_t lcss = get_embedded_data(m_dmrFrame+20, n_dmr);
        get_emb_data(m_dmrFrame+20, lcss);
    }
}

void DMR::encode16114(bool* d)
{
    d[11] = d[0] ^ d[1] ^ d[2] ^ d[3] ^ d[5] ^ d[7] ^ d[8];
    d[12] = d[1] ^ d[2] ^ d[3] ^ d[4] ^ d[6] ^ d[8] ^ d[9];
    d[13] = d[2] ^ d[3] ^ d[4] ^ d[5] ^ d[7] ^ d[9] ^ d[10];
    d[14] = d[0] ^ d[1] ^ d[2] ^ d[4] ^ d[6] ^ d[7] ^ d[10];
    d[15] = d[0] ^ d[2] ^ d[5] ^ d[6] ^ d[8] ^ d[9] ^ d[10];
}

void DMR::encode_qr1676(uint8_t* data)
{
    uint32_t value = (data[0U] >> 1) & 0x7FU;
    uint32_t cksum = ENCODING_TABLE_1676[value];

    data[0U] = cksum >> 8;
    data[1U] = cksum & 0xFFU;
}

void DMR::get_emb_data(uint8_t* data, uint8_t lcss)
{
    uint8_t DMREMB[2U];
    DMREMB[0U]  = (m_modeinfo.cc << 4) & 0xF0U;
    //DMREMB[0U] |= m_PI ? 0x08U : 0x00U;
    DMREMB[0U] |= (lcss << 1) & 0x06U;
    DMREMB[1U]  = 0x00U;

    encode_qr1676(DMREMB);

    data[13U] = (data[13U] & 0xF0U) | ((DMREMB[0U] >> 4U) & 0x0FU);
    data[14U] = (data[14U] & 0x0FU) | ((DMREMB[0U] << 4U) & 0xF0U);
    data[18U] = (data[18U] & 0xF0U) | ((DMREMB[1U] >> 4U) & 0x0FU);
    data[19U] = (data[19U] & 0x0FU) | ((DMREMB[1U] << 4U) & 0xF0U);
}

uint8_t DMR::get_embedded_data(uint8_t* data, uint8_t n)
{
    if (n >= 1U && n < 5U) {
        n--;

        bool bits[40U];
        ::memset(bits, 0x00U, 40U * sizeof(bool));
        ::memcpy(bits + 4U, m_raw + n * 32U, 32U * sizeof(bool));

        uint8_t bytes[5U];
        bitsToByteBE(bits + 0U,  bytes[0U]);
        bitsToByteBE(bits + 8U,  bytes[1U]);
        bitsToByteBE(bits + 16U, bytes[2U]);
        bitsToByteBE(bits + 24U, bytes[3U]);
        bitsToByteBE(bits + 32U, bytes[4U]);

        data[14U] = (data[14U] & 0xF0U) | (bytes[0U] & 0x0FU);
        data[15U] = bytes[1U];
        data[16U] = bytes[2U];
        data[17U] = bytes[3U];
        data[18U] = (data[18U] & 0x0FU) | (bytes[4U] & 0xF0U);

        switch (n) {
        case 0U:
            return 1U;
        case 3U:
            return 2U;
        default:
            return 3U;
        }
    } else {
        data[14U] &= 0xF0U;
        data[15U]  = 0x00U;
        data[16U]  = 0x00U;
        data[17U]  = 0x00U;
        data[18U] &= 0x0FU;

        return 0U;
    }
}

void DMR::encode_embedded_data(const uint8_t *lc)
{
    EmbeddedLC::encode(lc, m_raw);
}

void DMR::prepare_talker_alias()
{
    m_ta_dmra_sent = 0;
    m_modeinfo.usertxt.clear();
    m_ta_blocks = TalkerAlias::encode(m_talker_alias.toLatin1().toStdString(), m_ta_lc);
}

void DMR::send_talker_alias_block(unsigned int block)
{
    // Same packet MMDVMHost sends for a TA block it heard on RF (CDMRNetwork::writeTalkerAlias):
    // "DMRA" + source id (3) + block number + LC bytes 2..8. Once per block per transmission.
    if ((block > 3U) || (m_ta_dmra_sent & (1U << block)) || (m_udp == nullptr))
        return;
    m_ta_dmra_sent |= (uint8_t)(1U << block);

    QByteArray out;
    out.append("DMRA", 4);
    out.append((char)((m_dmrid >> 16) & 0xff));
    out.append((char)((m_dmrid >> 8) & 0xff));
    out.append((char)((m_dmrid >> 0) & 0xff));
    out.append((char)block);
    out.append((const char *)(m_ta_lc[block] + 2U), 7);
    m_udp->writeDatagram(out, m_address, m_modeinfo.port);
}

void DMR::rx_talker_alias_reset(uint32_t streamid)
{
    m_rx_ta_stream = streamid;
    m_rx_ta.reset();
    m_rx_emb_have = 0;
    m_modeinfo.usertxt.clear();
}

void DMR::rx_embedded_fragment(const uint8_t *burst, uint8_t flags)
{
    // flags = DMRD byte 15: 0x10 voice sync (burst A), otherwise the low nibble is the burst index.
    if (flags & 0x10U) {
        m_rx_emb_have = 0;
        return;
    }
    const uint8_t n = flags & 0x0FU;
    if ((n < 1U) || (n > 4U))
        return;
    EmbeddedLC::get_fragment(burst, m_rx_emb_raw, n - 1U);
    m_rx_emb_have |= (uint8_t)(1U << (n - 1U));
    if ((n == 4U) && (m_rx_emb_have == 0x0FU)) {
        m_rx_emb_have = 0;
        uint8_t lc[9U];
        if (EmbeddedLC::decode(m_rx_emb_raw, lc) && m_rx_ta.add(lc)) {
            rx_talker_alias_update();
        }
    }
}

void DMR::rx_talker_alias_update()
{
    if (!m_rx_ta.complete())
        return;
    const std::string raw = m_rx_ta.text();
    const QString alias = (m_rx_ta.format() == TalkerAlias::FORMAT_UTF8)
                              ? QString::fromUtf8(raw.data(), (qsizetype)raw.size())
                              : QString::fromLatin1(raw.data(), (qsizetype)raw.size());
    const QString clean = alias.simplified();
    if (clean != m_modeinfo.usertxt) {
        m_modeinfo.usertxt = clean;
        qDebug() << "DMR RX talker alias" << m_modeinfo.srcid << clean;
    }
}

void DMR::bitsToByteBE(const bool* bits, uint8_t& byte)
{
    byte  = bits[0U] ? 0x80U : 0x00U;
    byte |= bits[1U] ? 0x40U : 0x00U;
    byte |= bits[2U] ? 0x20U : 0x00U;
    byte |= bits[3U] ? 0x10U : 0x00U;
    byte |= bits[4U] ? 0x08U : 0x00U;
    byte |= bits[5U] ? 0x04U : 0x00U;
    byte |= bits[6U] ? 0x02U : 0x00U;
    byte |= bits[7U] ? 0x01U : 0x00U;
}

void DMR::byteToBitsBE(uint8_t byte, bool* bits)
{
    bits[0U] = (byte & 0x80U) == 0x80U;
    bits[1U] = (byte & 0x40U) == 0x40U;
    bits[2U] = (byte & 0x20U) == 0x20U;
    bits[3U] = (byte & 0x10U) == 0x10U;
    bits[4U] = (byte & 0x08U) == 0x08U;
    bits[5U] = (byte & 0x04U) == 0x04U;
    bits[6U] = (byte & 0x02U) == 0x02U;
    bits[7U] = (byte & 0x01U) == 0x01U;
}

void DMR::lc_get_data(bool* bits)
{
    uint8_t bytes[9U];
    memset(bytes, 0, 9);
    lc_get_data(bytes);

    byteToBitsBE(bytes[0U], bits + 0U);
    byteToBitsBE(bytes[1U], bits + 8U);
    byteToBitsBE(bytes[2U], bits + 16U);
    byteToBitsBE(bytes[3U], bits + 24U);
    byteToBitsBE(bytes[4U], bits + 32U);
    byteToBitsBE(bytes[5U], bits + 40U);
    byteToBitsBE(bytes[6U], bits + 48U);
    byteToBitsBE(bytes[7U], bits + 56U);
    byteToBitsBE(bytes[8U], bits + 64U);
}

void DMR::lc_get_data(uint8_t *bytes)
{
    bool pf, r;
    uint8_t fid, options;
    bytes[0U] = (uint8_t)m_flco;

    pf = (bytes[0U] & 0x80U) == 0x80U;
    r  = (bytes[0U] & 0x40U) == 0x40U;
    //m_flco = FLCO(bytes[0U] & 0x3FU);
    fid = bytes[1U];
    options = bytes[2U];

    //bytes[0U] = (uint8_t)m_flco;

    if (pf)
        bytes[0U] |= 0x80U;

    if (r)
        bytes[0U] |= 0x40U;

    bytes[1U] = fid;
    bytes[2U] = options;
    bytes[3U] = m_txdstid >> 16;
    bytes[4U] = m_txdstid >> 8;
    bytes[5U] = m_txdstid >> 0;
    bytes[6U] = m_dmrid >> 16;
    bytes[7U] = m_dmrid >> 8;
    bytes[8U] = m_dmrid >> 0;
}

void DMR::full_lc_encode(uint8_t* data, uint8_t type)  // for header
{
    uint8_t lcData[12U];
    uint8_t parity[4U];
    ::memset(lcData, 0, sizeof(lcData));
    lc_get_data(lcData);

    CRS129::encode(lcData, 9U, parity);

    switch (type) {
        case DT_VOICE_LC_HEADER:
            lcData[9U]  = parity[2U] ^ VOICE_LC_HEADER_CRC_MASK[0U];
            lcData[10U] = parity[1U] ^ VOICE_LC_HEADER_CRC_MASK[1U];
            lcData[11U] = parity[0U] ^ VOICE_LC_HEADER_CRC_MASK[2U];
            break;

        case DT_TERMINATOR_WITH_LC:
            lcData[9U]  = parity[2U] ^ TERMINATOR_WITH_LC_CRC_MASK[0U];
            lcData[10U] = parity[1U] ^ TERMINATOR_WITH_LC_CRC_MASK[1U];
            lcData[11U] = parity[0U] ^ TERMINATOR_WITH_LC_CRC_MASK[2U];
            break;

        default:
            return;
    }
    get_slot_data(data);
    m_bptc.encode(lcData, data);
}

void DMR::get_slot_data(uint8_t* data)
{
    uint8_t DMRSlotType[3U];
    DMRSlotType[0U]  = (m_modeinfo.cc << 4) & 0xF0U;
    DMRSlotType[0U] |= (m_dataType  << 0) & 0x0FU;
    DMRSlotType[1U]  = 0x00U;
    DMRSlotType[2U]  = 0x00U;

    CGolay2087::encode(DMRSlotType);

    data[12U] = (data[12U] & 0xC0U) | ((DMRSlotType[0U] >> 2) & 0x3FU);
    data[13U] = (data[13U] & 0x0FU) | ((DMRSlotType[0U] << 6) & 0xC0U) | ((DMRSlotType[1U] >> 2) & 0x30U);
    data[19U] = (data[19U] & 0xF0U) | ((DMRSlotType[1U] >> 2) & 0x0FU);
    data[20U] = (data[20U] & 0x03U) | ((DMRSlotType[1U] << 6) & 0xC0U) | ((DMRSlotType[2U] >> 2) & 0x3CU);
}


void DMR::addDMRDataSync(uint8_t* data, bool duplex)
{
    if (duplex) {
        for (uint32_t i = 0U; i < 7U; i++)
            data[i + 13U] = (data[i + 13U] & ~SYNC_MASK[i]) | BS_SOURCED_DATA_SYNC[i];
    } else {
        for (uint32_t i = 0U; i < 7U; i++)
            data[i + 13U] = (data[i + 13U] & ~SYNC_MASK[i]) | MS_SOURCED_DATA_SYNC[i];
    }
}

void DMR::addDMRAudioSync(uint8_t* data, bool duplex)
{
    if (duplex) {
        for (uint32_t i = 0U; i < 7U; i++)
            data[i + 13U] = (data[i + 13U] & ~SYNC_MASK[i]) | BS_SOURCED_AUDIO_SYNC[i];
    } else {
        for (uint32_t i = 0U; i < 7U; i++)
            data[i + 13U] = (data[i + 13U] & ~SYNC_MASK[i]) | MS_SOURCED_AUDIO_SYNC[i];
    }
}

void DMR::get_ambe()
{
#if !defined(Q_OS_IOS)
    uint8_t ambe[9];

    if(m_ambedev->get_ambe(ambe)){
        for(int i = 0; i < 9; ++i){
            m_txcodecq.append(ambe[i]);
        }
    }
#endif
}

// Keep a copy of what we play so the transmission can be replayed later.
// A different src/dst means a new transmission started before the old one was closed.
void DMR::record_rx(const int16_t *pcm)
{
    if (m_recorder.active() &&
        ((m_recorder.streamSrc() != m_modeinfo.srcid) || (m_recorder.streamDst() != m_modeinfo.dstid))) {
        finish_recording();
    }
    if (!m_recorder.active()) {
        m_recorder.begin(m_modeinfo.srcid, m_modeinfo.dstid);
        // Live subtitles: decided once per transmission (TG list in Settings > Subtitles).
        m_subtitle_on = SubtitleTap::wants(m_modeinfo.dstid);
        if (m_subtitle_on) SubtitleTap::begin(m_modeinfo.srcid, m_modeinfo.dstid, m_recorder.baseName());
    }
    m_recorder.append(pcm, 160);
    // Post-gain PCM, same frames as the speaker; only queued, never waits for the recognizer.
    if (m_subtitle_on) SubtitleTap::push(pcm, 160);
}

void DMR::finish_recording()
{
    const QString path = m_recorder.finish();
    if (m_subtitle_on) {
        m_subtitle_on = false;
        SubtitleTap::end();
    }
    if (!path.isEmpty()) {
        emit recording_saved(path);
    }
}

void DMR::process_rx_data()
{
    int16_t pcm[160];
    uint8_t ambe[9];
    static uint8_t cnt = 0;

    if(m_rxwatchdog++ > 100){
        qDebug() << "DMR RX stream timeout ";
        m_rxwatchdog = 0;
        m_modeinfo.stream_state = STREAM_LOST;
        m_modeinfo.ts = QDateTime::currentMSecsSinceEpoch();
        emit update(m_modeinfo);
        m_modeinfo.streamid = 0;
    }

    if((m_rxmodemq.size() > 2) && (++cnt >= 3)){
        QByteArray out;
        int s = m_rxmodemq[1];
        if((m_rxmodemq[0] == MMDVM_FRAME_START) && (m_rxmodemq.size() >= s)){
            for(int i = 0; i < s; ++i){
                out.append(m_rxmodemq.dequeue());
            }
#if !defined(Q_OS_IOS)
            m_modem->write(out);
#endif
        }
        cnt = 0;
    }

    if((!m_tx) && (m_rxcodecq.size() > 8) ){
        for(int i = 0; i < 9; ++i){
            ambe[i] = m_rxcodecq.dequeue();
        }
        if(m_hwrx){
#if !defined(Q_OS_IOS)
            m_ambedev->decode(ambe);

            if(m_ambedev->get_audio(pcm)){
                record_rx(pcm);
                m_audio->write(pcm, 160);
                emit update_output_level(m_audio->level());
            }
#endif
        }
        else{
            if(m_modeinfo.sw_vocoder_loaded){
#ifdef USE_MD380_VOCODER
                md380_decode_fec(ambe, pcm);
#else
                m_mbevocoder->decode_2450x1150(pcm, ambe);
#endif
            }
            else{
                memset(pcm, 0, 160 * sizeof(int16_t));
            }
            apply_rx_gain(pcm, 160);
            record_rx(pcm);
            ++m_rx_frames_decoded;
            m_audio->write(pcm, 160);
            emit update_output_level(m_audio->level());
        }
    }
    else if ( ((m_modeinfo.stream_state == STREAM_END) || (m_modeinfo.stream_state == STREAM_LOST)) && (m_rxmodemq.size() < 50) ){
        m_rxtimer->stop();
        m_audio->stop_playback();
        m_rxwatchdog = 0;
        m_modeinfo.streamid = 0;
        m_rxcodecq.clear();
        qDebug() << "DMR playback stopped: voice frames in" << m_rx_frames_in << "decoded 20ms blocks" << m_rx_frames_decoded << "m_tx" << m_tx;
        finish_recording();
        m_modeinfo.stream_state = STREAM_IDLE;
        return;
    }
}
