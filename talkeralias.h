/*
    DMR Talker Alias (ETSI TS 102 361-2 7.1.1.2), header-only and Qt-free so it can be unit tested.

    Byte layout matches MMDVMHost (DMRSlot.cpp / DMRTA.cpp / DMRNetwork::writeTalkerAlias):
      every TA LC is 9 bytes: byte0 = FLCO (4 = header, 5..7 = block 1..3, PF/R = 0), byte1 = FID 0x00
      header byte2 = (format << 6) | (length << 1) | spare bit, bytes 3..8 = first 6 characters
      block N bytes 2..8 = next 7 characters each
    MMDVMHost concatenates bytes 2..8 of each LC into one buffer; buf[0] is the format/length byte and
    for the 8-bit formats the text is buf[1..] (the spare bit is ignored). So ISO 8-bit carries at most
    6 + 3 * 7 = 27 characters.

    This program is free software: you can redistribute it and/or modify it under the terms of the
    GNU General Public License as published by the Free Software Foundation, either version 3 of the
    License, or (at your option) any later version.
*/

#ifndef TALKERALIAS_H
#define TALKERALIAS_H

#include <cstdint>
#include <cstring>
#include <string>

namespace TalkerAlias {

static const uint8_t FORMAT_7BIT  = 0U;
static const uint8_t FORMAT_ISO8  = 1U;
static const uint8_t FORMAT_UTF8  = 2U;
static const uint8_t FORMAT_UTF16 = 3U;

static const uint8_t FLCO_HEADER = 4U;
static const unsigned int MAX_CHARS_8BIT = 27U;

// Builds the TA LCs for an ISO 8-bit text. Returns the number of LCs (1..4) or 0 for an empty text.
// Only the blocks the length needs are produced: <=6 chars header only, <=13 +block1, <=20 +block2.
inline unsigned int encode(const std::string &text, uint8_t lc[4][9])
{
    unsigned int len = (unsigned int)text.size();
    if (len > MAX_CHARS_8BIT)
        len = MAX_CHARS_8BIT;
    if (len == 0U)
        return 0U;

    uint8_t chars[MAX_CHARS_8BIT];
    ::memset(chars, 0x00U, sizeof(chars));
    ::memcpy(chars, text.data(), len);

    unsigned int blocks = 1U;
    if (len > 6U)  blocks = 2U;
    if (len > 13U) blocks = 3U;
    if (len > 20U) blocks = 4U;

    for (unsigned int b = 0U; b < blocks; b++) {
        ::memset(lc[b], 0x00U, 9U);
        lc[b][0U] = (uint8_t)(FLCO_HEADER + b);
        lc[b][1U] = 0x00U;
        if (b == 0U) {
            lc[b][2U] = (uint8_t)((FORMAT_ISO8 << 6) | ((len & 0x1FU) << 1));
            ::memcpy(lc[b] + 3U, chars, 6U);
        } else {
            ::memcpy(lc[b] + 2U, chars + 6U + (b - 1U) * 7U, 7U);
        }
    }
    return blocks;
}

// Collects TA LCs from a received stream (any order) and decodes them like MMDVMHost's CDMRTA.
class Decoder {
public:
    Decoder() { reset(); }

    void reset()
    {
        ::memset(m_buf, 0x00U, sizeof(m_buf));
        m_have = 0U;
    }

    // lc: the 9 LC bytes (FLCO in the low 6 bits of byte0). Returns true if this LC was a TA LC.
    bool add(const uint8_t *lc)
    {
        uint8_t flco = lc[0U] & 0x3FU;
        if (flco < FLCO_HEADER || flco > FLCO_HEADER + 3U)
            return false;
        unsigned int block = flco - FLCO_HEADER;
        return addBlock(block, lc + 2U);
    }

    // block 0..3, data = LC bytes 2..8 (also the payload of a homebrew "DMRA" packet)
    bool addBlock(unsigned int block, const uint8_t *data7)
    {
        if (block > 3U)
            return false;
        ::memcpy(m_buf + block * 7U, data7, 7U);
        m_have |= (uint8_t)(1U << block);
        return true;
    }

    bool hasHeader() const { return (m_have & 0x01U) != 0U; }
    unsigned int format() const { return (m_buf[0U] >> 6) & 0x03U; }
    unsigned int length() const { return (m_buf[0U] >> 1) & 0x1FU; }

    // All blocks needed for the announced length have arrived.
    bool complete() const
    {
        if (!hasHeader())
            return false;
        unsigned int bits;
        switch (format()) {
        case FORMAT_7BIT:  bits = length() * 7U;  break;
        case FORMAT_UTF16: bits = length() * 16U; break;
        default:           bits = length() * 8U;  break;
        }
        // header carries 49 data bits (48 usable for the 8/16-bit formats), each block 56
        unsigned int avail = (format() == FORMAT_7BIT) ? 49U : 48U;
        unsigned int need = 1U;
        while (avail < bits && need < 4U) { avail += 56U; need++; }
        uint8_t mask = (uint8_t)((1U << need) - 1U);
        return (m_have & mask) == mask;
    }

    // Decoded text so far (Latin-1/ASCII bytes; UTF-8 bytes for format 2). Empty without a header.
    std::string text() const
    {
        std::string out;
        if (!hasHeader())
            return out;
        unsigned int size = length();
        switch (format()) {
        case FORMAT_7BIT: {
            unsigned int t1 = 0U, t2 = 0U;
            uint8_t c = 0U;
            for (unsigned int i = 0U; (i < 28U) && (t2 < size); i++) {
                for (int j = 7; j >= 0 && t2 < size; j--) {
                    c = (uint8_t)((c << 1) | ((m_buf[i] >> j) & 1U));
                    if (++t1 == 7U) {
                        if (i > 0U) { out.push_back((char)(c & 0x7FU)); t2++; }
                        t1 = 0U;
                        c = 0U;
                    }
                }
            }
            break;
        }
        case FORMAT_UTF16:
            for (unsigned int i = 0U; (i < 13U) && (out.size() < size); i++) {
                uint8_t hi = m_buf[2U * i + 1U], lo = m_buf[2U * i + 2U];
                out.push_back(hi == 0U ? (char)lo : '?');
            }
            break;
        default:
            for (unsigned int i = 0U; (i < 27U) && (out.size() < size); i++)
                out.push_back((char)m_buf[1U + i]);
            break;
        }
        // stop at padding from blocks that have not arrived yet
        size_t z = out.find('\0');
        if (z != std::string::npos)
            out.resize(z);
        while (!out.empty() && out.back() == ' ')
            out.pop_back();
        return out;
    }

private:
    uint8_t m_buf[28];
    uint8_t m_have;
};

} // namespace TalkerAlias

// Embedded LC (voice bursts B..E): 72-bit LC + 5-bit checksum, Hamming (16,11,4) rows + column parity,
// interleaved into 128 bits. Same algorithm as MMDVMHost CDMREmbeddedData::encode/decodeEmbeddedData.
namespace EmbeddedLC {

inline void hamming16114(bool *d)
{
    d[11] = d[0] ^ d[1] ^ d[2] ^ d[3] ^ d[5] ^ d[7] ^ d[8];
    d[12] = d[1] ^ d[2] ^ d[3] ^ d[4] ^ d[6] ^ d[8] ^ d[9];
    d[13] = d[2] ^ d[3] ^ d[4] ^ d[5] ^ d[7] ^ d[9] ^ d[10];
    d[14] = d[0] ^ d[1] ^ d[2] ^ d[4] ^ d[6] ^ d[7] ^ d[10];
    d[15] = d[0] ^ d[2] ^ d[5] ^ d[6] ^ d[8] ^ d[9] ^ d[10];
}

inline uint32_t checksum(const uint8_t *lc)
{
    uint32_t total = 0U;
    for (unsigned int i = 0U; i < 9U; i++)
        total += lc[i];
    return total % 31U;
}

// Payload bit positions inside the 128-bit (de-interleaved) matrix, in LC bit order.
inline unsigned int payload_positions(unsigned int *pos)
{
    static const unsigned int ranges[7][2] = {{0U, 11U}, {16U, 27U}, {32U, 42U}, {48U, 58U}, {64U, 74U}, {80U, 90U}, {96U, 106U}};
    unsigned int n = 0U;
    for (unsigned int r = 0U; r < 7U; r++)
        for (unsigned int a = ranges[r][0]; a < ranges[r][1]; a++)
            pos[n++] = a;
    return n; // 72
}

inline void encode(const uint8_t *lc, bool *raw)
{
    bool data[128U];
    ::memset(data, 0x00U, sizeof(data));

    uint32_t crc = checksum(lc);
    data[106U] = (crc & 0x01U) == 0x01U;
    data[90U]  = (crc & 0x02U) == 0x02U;
    data[74U]  = (crc & 0x04U) == 0x04U;
    data[58U]  = (crc & 0x08U) == 0x08U;
    data[42U]  = (crc & 0x10U) == 0x10U;

    unsigned int pos[72U];
    payload_positions(pos);
    for (unsigned int i = 0U; i < 72U; i++)
        data[pos[i]] = ((lc[i / 8U] >> (7U - (i % 8U))) & 1U) == 1U;

    for (unsigned int a = 0U; a < 112U; a += 16U)
        hamming16114(data + a);
    for (unsigned int a = 0U; a < 16U; a++)
        data[a + 112U] = data[a + 0U] ^ data[a + 16U] ^ data[a + 32U] ^ data[a + 48U] ^ data[a + 64U] ^ data[a + 80U] ^ data[a + 96U];

    // packed downwards in columns
    unsigned int b = 0U;
    for (unsigned int a = 0U; a < 128U; a++) {
        raw[a] = data[b];
        b += 16U;
        if (b > 127U)
            b -= 127U;
    }
}

// Returns false if any Hamming row, column parity or the checksum fails (no error correction:
// network frames are regenerated by the master and arrive error free).
inline bool decode(const bool *raw, uint8_t *lc)
{
    bool data[128U];
    unsigned int b = 0U;
    for (unsigned int a = 0U; a < 128U; a++) {
        data[b] = raw[a];
        b += 16U;
        if (b > 127U)
            b -= 127U;
    }

    for (unsigned int a = 0U; a < 112U; a += 16U) {
        bool row[16U];
        ::memcpy(row, data + a, sizeof(row));
        hamming16114(row);
        if (::memcmp(row, data + a, sizeof(row)) != 0)
            return false;
    }
    for (unsigned int a = 0U; a < 16U; a++) {
        if (data[a + 0U] ^ data[a + 16U] ^ data[a + 32U] ^ data[a + 48U] ^ data[a + 64U] ^ data[a + 80U] ^ data[a + 96U] ^ data[a + 112U])
            return false;
    }

    unsigned int pos[72U];
    payload_positions(pos);
    ::memset(lc, 0x00U, 9U);
    for (unsigned int i = 0U; i < 72U; i++)
        if (data[pos[i]])
            lc[i / 8U] |= (uint8_t)(0x80U >> (i % 8U));

    uint32_t crc = 0U;
    if (data[42])  crc += 16U;
    if (data[58])  crc += 8U;
    if (data[74])  crc += 4U;
    if (data[90])  crc += 2U;
    if (data[106]) crc += 1U;
    return crc == checksum(lc);
}

// Voice burst fragment (bursts B..E carry 32 raw bits each in bytes 14..18 of the 33-byte payload).
inline void put_fragment(uint8_t *burst, const bool *raw, unsigned int n /* 0..3 */)
{
    bool bits[40U];
    ::memset(bits, 0x00U, sizeof(bits));
    ::memcpy(bits + 4U, raw + n * 32U, 32U * sizeof(bool));
    uint8_t bytes[5U];
    for (unsigned int i = 0U; i < 5U; i++) {
        bytes[i] = 0U;
        for (unsigned int j = 0U; j < 8U; j++)
            if (bits[i * 8U + j]) bytes[i] |= (uint8_t)(0x80U >> j);
    }
    burst[14U] = (burst[14U] & 0xF0U) | (bytes[0U] & 0x0FU);
    burst[15U] = bytes[1U];
    burst[16U] = bytes[2U];
    burst[17U] = bytes[3U];
    burst[18U] = (burst[18U] & 0x0FU) | (bytes[4U] & 0xF0U);
}

inline void get_fragment(const uint8_t *burst, bool *raw, unsigned int n /* 0..3 */)
{
    uint32_t v = ((uint32_t)(burst[14U] & 0x0FU) << 28) | ((uint32_t)burst[15U] << 20) |
                 ((uint32_t)burst[16U] << 12) | ((uint32_t)burst[17U] << 4) | ((uint32_t)(burst[18U] >> 4) & 0x0FU);
    for (unsigned int i = 0U; i < 32U; i++)
        raw[n * 32U + i] = ((v >> (31U - i)) & 1U) == 1U;
}

} // namespace EmbeddedLC

#endif // TALKERALIAS_H
