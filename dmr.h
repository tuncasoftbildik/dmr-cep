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

#ifndef DMR_H
#define DMR_H

#include "mode.h"
#include "rxrecorder.h"
#include "DMRDefines.h"
#include "cbptc19696.h"

class DMR : public Mode
{
    Q_OBJECT
public:
    DMR();
    ~DMR();
    void set_dmr_params(uint8_t essid, QString password, QString lat, QString lon, QString location, QString desc, QString freq, QString url, QString swid, QString pkid, QString options);
    uint8_t * get_eot();
private slots:
    void process_udp();
    void process_rx_data();
    void process_modem_data(QByteArray);
    void get_ambe();
    void send_ping();
    void send_disconnect();
    void transmit();
    void hostname_lookup(QHostInfo i);
    void dmr_tgid_changed(int id) { m_txdstid = id; }
    void dmrpc_state_changed(int p){m_flco = p ? FLCO_USER_USER : FLCO_GROUP; }
    void cc_changed(int cc) {m_txcc = cc;}
    void slot_changed(int s) {m_txslot = s + 1; }
    void send_frame();
    void resend_handshake();
private:
    // Login/auth/config are single UDP packets with no retransmit in the protocol; one lost
    // reply used to leave the connect hanging until the 15 s timeout.
    static const int HANDSHAKE_RESEND_MS = 3000;
    static const int HANDSHAKE_MAX_RESENDS = 3;
    void send_handshake(const QByteArray &out);
    QTimer *m_handshake_timer = nullptr;
    QByteArray m_last_handshake;
    int m_handshake_resends = 0;
    // TX diagnostics / recovery
    int m_tx_frames = 0;
    int m_tx_starved = 0;
    int m_tx_peak = 0;
    bool m_tx_logged = false;
    bool m_tx_mic_restarted = false;
    // Last TX kept as two 8 kHz WAVs in AppData: what went into the vocoder (tx_last_mic.wav)
    // and what a listener decodes from our AMBE (tx_last_decoded.wav).
    QByteArray m_tx_mic_pcm;
    QByteArray m_tx_loop_pcm;
#ifndef VOCODER_PLUGIN
    VocoderPlugin *m_tx_loop_vocoder = nullptr;
#endif
    void save_tx_debug_audio();
    // Roger beep: short chirp replaces the first ~70 ms, two-tone tail is sent before the EOT.
    QVector<int16_t> m_roger_head;
    QVector<int16_t> m_roger_tail;
    int m_roger_head_pos = 0;
    int m_roger_tail_pos = 0;
    bool m_roger_tail_started = false;
    // RX diagnostics: voice frames queued vs decoded per stream.
    int m_rx_frames_in = 0;
    int m_rx_frames_decoded = 0;
    // TX automatic gain (iPhone mic arrives around -40 dBFS).
    float m_tx_gain = 2.0f;
    float m_tx_noise_floor = 300.0f;   // tracked RMS of the room between words
    float m_tx_gate = 1.0f;            // 1 = open, 0.25 = closed (-12 dB)
    void apply_tx_gain(int16_t *pcm, int n);
    // TX voice shaping at 8 kHz before the vocoder: 4th-order high-pass (tone setting) + mild presence peak.
public:
    struct Bq { float b0, b1, b2, a1, a2, z1 = 0, z2 = 0; };
private:
    Bq m_tx_hpf{}, m_tx_hpf2{}, m_tx_peq{};
    bool m_tx_filters_ready = false;
    void tx_shape(int16_t *pcm, int n);
    // RX output AGC (decoded AMBE arrives around -36 dBFS, too quiet for the iPhone speaker).
    float m_rx_gain = 8.0f;
    float m_rx_last_gain = 8.0f;
    void apply_rx_gain(int16_t *pcm, int n);
    static const qint64 RX_WATCHDOG_MS = 20000;
    void report_connection_lost(const QString &reason);
    void record_rx(const int16_t *pcm);
    void finish_recording();
    RxRecorder m_recorder;
    qint64 m_last_rx_ms = 0;
    bool m_link_lost = false;
    uint32_t m_essid;
    QString m_password;
    QString m_lat;
    QString m_lon;
    QString m_location;
    QString m_desc;
    QString m_freq;
    QString m_url;
    QString m_swid;
    QString m_pkid;
    uint32_t m_txsrcid;
    uint32_t m_txdstid;
    uint32_t m_txstreamid;
    uint8_t m_txslot;
    uint8_t m_txcc;
    uint8_t packet_size;
    uint8_t m_ambe[27];
    uint32_t m_defsrcid;
    uint8_t m_dmrFrame[55];
    uint8_t m_dataType;
    uint32_t m_dmrcnt;
    FLCO m_flco;
    CBPTC19696 m_bptc;
    bool m_raw[128U];
    bool m_data[72U];
    QString m_options;

    void byteToBitsBE(uint8_t byte, bool* bits);
    void bitsToByteBE(const bool* bits, uint8_t& byte);
    void build_frame();
    void encode_header(uint8_t);
    void encode_data();
    void encode16114(bool* d);
    void encode_qr1676(uint8_t* data);
    void get_slot_data(uint8_t* data);
    void lc_get_data(uint8_t*);
    void lc_get_data(bool* bits);
    void encode_embedded_data();
    uint8_t get_embedded_data(uint8_t* data, uint8_t n);
    void get_emb_data(uint8_t* data, uint8_t lcss);
    void full_lc_encode(uint8_t* data, uint8_t type);
    void addDMRDataSync(uint8_t* data, bool duplex);
    void addDMRAudioSync(uint8_t* data, bool duplex);
    void setup_connection();
};

#endif // DMR_H
