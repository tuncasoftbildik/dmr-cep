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
#include <QElapsedTimer>
#include "talkeralias.h"
#include <QSet>

class DMR : public Mode
{
    Q_OBJECT
public:
    DMR();
    ~DMR();
    void set_dmr_params(uint8_t essid, QString password, QString lat, QString lon, QString location, QString desc, QString freq, QString url, QString swid, QString pkid, QString options);
    uint8_t * get_eot();
signals:
    // The master answered an RPTG position update with MSTNAK/MSTCL: do not send RPTG to it again.
    void position_update_rejected();
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
    // New hotspot position (strings with 4 decimals). Stored for the next RPTC login and,
    // while linked, sent to the master as RPTG (DMRGateway's writeHomePosition format).
    void send_position(QString lat, QString lon);
    // Listen filter: "" = hear every talkgroup; "on:91,28634" = only these group calls (plus the
    // TX talkgroup and private calls). Muted streams are dropped before audio, UI and recording.
    void set_rx_filter(QString filter);
private:
    bool rx_muted(const QByteArray &buf);
    bool m_rx_filter_on = false;
    QSet<uint32_t> m_rx_allow;
    uint32_t m_rx_muted_stream = 0;
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
    qint64 m_tx_start_ms = 0;
#ifndef VOCODER_PLUGIN
    VocoderPlugin *m_tx_loop_vocoder = nullptr;
#endif
    void save_tx_debug_audio();
    // Roger tones (key-up and release), sent as AMBE+2 tone frames; see roger_head/tail_frames().
    bool m_roger_tail_started = false;
    QVector<int> roger_head_frames() const;
    QVector<int> roger_tail_frames() const;
    // 5-tone ANI (ZVEI-1) sent as AMBE+2 tone frames: one entry per 20 ms frame, tone index
    // (f = index * 31.25 Hz) or 0 for a silent frame.
    QVector<int> m_ani_head;
    QVector<int> m_ani_tail;
    QVector<int> build_ani() const;
    QVector<int> build_ccir(const QString &digits) const;
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
    // Link quality ("signal bars"): measured from traffic that flows anyway, no extra packets.
    //  - RTT of each RPTPING -> MSTPONG (last + EWMA),
    //  - ping loss over the last LQ_PING_WINDOW pings (a ping without a pong before the next one),
    //  - voice frame loss from gaps in the DMRD sequence byte (buf[4]) of the current/last RX stream,
    //  - RX inter-arrival jitter (RFC 3550 style, against the nominal 60 ms per DMRD voice packet).
    static const int LQ_PING_WINDOW = 10;
    static const qint64 LQ_EMIT_MIN_MS = 1000;
    static const qint64 LQ_LOG_INTERVAL_MS = 60000;
    static const qint64 LQ_RX_LOSS_RELEVANT_MS = 120000;   // a stream's loss counts in the score this long after it ended
    QElapsedTimer m_lq_ping_clock;
    bool m_lq_ping_pending = false;
    int m_lq_rtt_last = -1;          // ms, -1 = no pong yet
    double m_lq_rtt_avg = -1;        // ms, EWMA (alpha 0.25)
    quint16 m_lq_ping_hist = 0;      // bit i = 1: ping i (newest = bit 0) got no pong
    int m_lq_ping_count = 0;         // pings resolved so far (capped at LQ_PING_WINDOW)
    int m_lq_consecutive_miss = 0;
    uint32_t m_lq_streamid = 0;
    int m_lq_last_seq = -1;
    int m_lq_rx_received = 0;
    int m_lq_rx_lost = 0;
    int m_lq_rx_loss_pct = -1;       // -1 = nothing received yet this session
    double m_lq_jitter = 0;          // ms
    bool m_lq_prev_voice = false;
    qint64 m_lq_last_frame_ms = 0;
    qint64 m_lq_stream_end_ms = 0;
    qint64 m_lq_last_emit_ms = 0;
    qint64 m_lq_last_log_ms = 0;
    QString m_lq_emitted_sig;
    void lq_ping_sent();
    void lq_pong_received();
    void lq_track_rx(const QByteArray &buf);
    void lq_stream_ended();
    int lq_ping_loss_pct() const;
    int lq_bars() const;
    void lq_emit(bool force);
    void report_connection_lost(const QString &reason);
    void record_rx(const int16_t *pcm);
    void finish_recording();
    RxRecorder m_recorder;
    bool m_subtitle_on = false;          // this transmission goes to the subtitle engine
    qint64 m_last_rx_ms = 0;
    bool m_link_lost = false;
    uint32_t m_essid;
    QString m_password;
    QString m_lat;
    QString m_lon;
    qint64 m_rptg_sent_ms = 0;
    static const qint64 RPTG_REJECT_WINDOW_MS = 5000;
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
    // Talker Alias TX: TA LCs (header + blocks) built at key-up from Mode::m_talker_alias, sent in the
    // embedded LC of every other voice superframe; each block also goes to the master once as "DMRA".
    uint8_t m_ta_lc[4][9];
    unsigned int m_ta_blocks = 0;
    uint8_t m_ta_dmra_sent = 0;
    void prepare_talker_alias();
    void send_talker_alias_block(unsigned int block);
    // Talker Alias RX: embedded LC fragments of bursts B..E and the alias assembled per stream.
    bool m_rx_emb_raw[128U];
    uint8_t m_rx_emb_have = 0;
    uint32_t m_rx_ta_stream = 0;
    TalkerAlias::Decoder m_rx_ta;
    void rx_talker_alias_reset(uint32_t streamid);
    void rx_embedded_fragment(const uint8_t *burst, uint8_t flags);
    void rx_talker_alias_update();

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
    void encode_embedded_data(const uint8_t *lc);
    uint8_t get_embedded_data(uint8_t* data, uint8_t n);
    void get_emb_data(uint8_t* data, uint8_t lcss);
    void full_lc_encode(uint8_t* data, uint8_t type);
    void addDMRDataSync(uint8_t* data, bool duplex);
    void addDMRAudioSync(uint8_t* data, bool duplex);
    void setup_connection();
};

#endif // DMR_H
