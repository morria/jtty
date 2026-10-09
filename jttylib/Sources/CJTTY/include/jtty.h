// JTTY modem: source codec, FEC, waveform synthesis and receiver.
//
// Written from the protocol description that ships with WSJT-X 3.2
// (lib/jtty/jtty_design.md and jtty_source_encoding.txt, Joe Taylor K1JT
// and the WSJT development group). The protocol is theirs; this
// implementation is independent and carries no WSJT-X code.
//
// Numbers worth having in one place:
//   12000 S/s audio in, 384 samples per symbol, 31.25 baud
//   13 sync symbols + 46 data symbols = 59 per frame = 1.888 s
//   4-GFSK, BT 2.0, tone spacing = baud, occupied bandwidth ~127 Hz
//   34 payload bits + CRC-12 = 46 bits -> rate 1/2 tail-biting
//   convolutional code, K=10, polynomials 1167/1545 octal -> 92 bits
//   -> 46 two-bit Gray-coded tones.
#ifndef JTTY_H
#define JTTY_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define JTTY_SAMPLE_RATE 12000
#define JTTY_NSPS 384
#define JTTY_SYNC_SYMBOLS 13
#define JTTY_DATA_SYMBOLS 46
#define JTTY_FRAME_SYMBOLS 59
#define JTTY_FRAME_SAMPLES (JTTY_FRAME_SYMBOLS * JTTY_NSPS)
#define JTTY_MAX_FRAMES 16
#define JTTY_MAX_TEXT 80
#define JTTY_PAYLOAD_BITS 34
#define JTTY_INFO_BITS 46

// The receiver works on windows of 1.25 frames, advanced a quarter frame at
// a time.
#define JTTY_STEP_SAMPLES (JTTY_FRAME_SAMPLES / 4)
#define JTTY_CHUNK_SAMPLES (JTTY_FRAME_SAMPLES + JTTY_STEP_SAMPLES)

// MARK: - Source grammar

enum {
    JTTY_ATOM_CALL = 0,
    JTTY_ATOM_EXCH_NUM = 1,
    JTTY_ATOM_EXCH_LOC = 2,
    JTTY_ATOM_EXCH_PAIR = 3,
    JTTY_ATOM_EXCH_NUM_TIME = 4,
    JTTY_ATOM_CONTROL = 5,
    JTTY_ATOM_GRID4 = 6,
    JTTY_ATOM_TEXT5 = 7,
};

enum {
    JTTY_CALL_CQ = 0,      // CQ <call> CQ
    JTTY_CALL_CALL = 1,    // <call>
    JTTY_CALL_TU_CQ = 2,   // TU <call> CQ
    JTTY_CALL_CALL_TU = 3, // <call> TU
    JTTY_CALL_AGN = 4,     // <call> AGN?
    JTTY_CALL_TU_NOW = 5,  // TU NOW <call>
};

enum { JTTY_ROLE_FIELD_ONLY = 0, JTTY_ROLE_FULL = 1 };

enum {
    JTTY_NUM_SERIAL = 0, JTTY_NUM_CQ_ZONE = 1, JTTY_NUM_ITU_ZONE = 2,
    JTTY_NUM_AGE = 3, JTTY_NUM_POWER = 4, JTTY_NUM_CHECK = 5,
    JTTY_NUM_LICENSE_YEAR = 6, JTTY_NUM_GENERIC = 7,
};

enum {
    JTTY_LOC_STATE_PROVINCE = 0, JTTY_LOC_SECTION = 1,
    JTTY_LOC_COUNTRY_PREFIX = 2, JTTY_LOC_QTH = 3, JTTY_LOC_ADMIN_CODE = 4,
};

enum { JTTY_PAIR_ZONE_LOC3 = 0, JTTY_PAIR_CLASS_SECTION = 1 };

enum {
    JTTY_CONTROL_AGN = 0, JTTY_CONTROL_CALL = 1, JTTY_CONTROL_AGN_CALL = 2,
    JTTY_CONTROL_NR = 3, JTTY_CONTROL_AGN_NR = 4, JTTY_CONTROL_EXCH = 5,
    JTTY_CONTROL_STATE = 6, JTTY_CONTROL_SECTION = 7, JTTY_CONTROL_ZONE = 8,
    JTTY_CONTROL_GRID = 9, JTTY_CONTROL_RPRT = 10, JTTY_CONTROL_QSL_TU = 11,
    JTTY_CONTROL_TU = 12, JTTY_CONTROL_QRZ = 13, JTTY_CONTROL_QSO_B4 = 14,
    JTTY_CONTROL_WAIT = 15, JTTY_CONTROL_NIL = 16, JTTY_CONTROL_OK = 17,
    JTTY_CONTROL_COUNT = 18,
};

enum {
    JTTY_PROFILE_UNKNOWN = 0,
    JTTY_PROFILE_FIELD_DAY = 1,
    JTTY_PROFILE_RTTY_ROUNDUP = 2,
};

/// One source atom. Which fields matter depends on `kind`:
///   CALL:          subtype = action, text = callsign
///   EXCH_NUM:      role, subtype = number kind, value
///   EXCH_LOC:      role, subtype = location kind, text = 2-3 base-36 chars
///   EXCH_PAIR:     subtype = schema; ZONE_LOC3: value = zone, text = token;
///                  CLASS_SECTION: value = count, text = class letter,
///                  value2 = section index 1..86
///   EXCH_NUM_TIME: role, value = serial, value2 = minute of day
///   CONTROL:       subtype = phrase id
///   GRID4:         role, text = grid
///   TEXT5:         text = up to five characters
typedef struct {
    int kind;
    int subtype;
    int role;
    int value;
    int value2;
    char text[14];
} jtty_atom;

/// The 64-character source alphabet, indexed by six-bit value.
extern const char jtty_alphabet[65];
/// Control phrases, indexed by id.
extern const char *const jtty_control_phrases[JTTY_CONTROL_COUNT];
/// ARRL/RAC sections, 1-based (index 0 unused).
extern const char *const jtty_arrl_sections[87];
/// Index of a section name, or 0.
int jtty_section_index(const char *section);

/// Pack one atom into the 34-bit frame payload (bit 1 is the most significant
/// of the 34). Returns false if the atom is not valid.
bool jtty_pack_atom(const jtty_atom *atom, bool eom, uint64_t *payload);
/// Unpack and fully validate a 34-bit payload. False for anything the
/// grammar rejects, including the all-zero sentinel and a set reserved bit.
bool jtty_unpack_atom(uint64_t payload, jtty_atom *atom, bool *eom);
/// Canonical text of an atom. TEXT5 renders its five characters verbatim.
bool jtty_render_atom(const jtty_atom *atom, char text[JTTY_MAX_TEXT + 1]);

/// Unpack a payload straight to display text. TEXT5 spaces come out as '~'
/// so the receiver can tell protocol spacing from padding; `trailing_sep` is
/// set when the atom was structured and so implies one following space.
bool jtty_unpack_frame(uint64_t payload, char text[JTTY_MAX_TEXT + 1],
                       bool *trailing_sep, bool *eom);

/// Fold operator text into the source alphabet: uppercase, unsupported
/// characters to '#', runs of spaces collapsed, leading space dropped.
void jtty_normalize(const char *input, char output[JTTY_MAX_TEXT + 1]);

/// Whether a callsign fits the protocol's 28-bit call field.
bool jtty_is_standard_call(const char *callsign);

/// Pack free text into the fewest frames. `profile` is one of JTTY_PROFILE_*.
/// `normalized` receives the text as it will actually be sent (after
/// normalisation and, under RTTY Roundup, serial canonicalisation).
/// Returns the frame count, 0 for empty text, or -1 if it cannot be sent.
int jtty_pack_text(const char *text, int profile,
                   uint64_t payloads[JTTY_MAX_FRAMES],
                   char normalized[JTTY_MAX_TEXT + 1]);

/// Pack a sequence of native atoms, setting EOM on the last.
bool jtty_pack_atoms(const jtty_atom *atoms, int count,
                     uint64_t payloads[JTTY_MAX_FRAMES]);

// MARK: - FEC

/// Append CRC-12 and encode one 34-bit payload to 46 tones.
void jtty_encode_frame(uint64_t payload, uint8_t tones[JTTY_DATA_SYMBOLS]);
/// Full frame including the 13-symbol sync.
void jtty_frame_tones(uint64_t payload, uint8_t tones[JTTY_FRAME_SYMBOLS]);
/// The sync sequence.
extern const uint8_t jtty_sync_tones[JTTY_SYNC_SYMBOLS];

/// Decode 46 symbols of complex tone correlations (4 per symbol) and the
/// half-symbol energy observations. Returns true and the payload on success.
bool jtty_decode_frame(const float correlations[JTTY_DATA_SYMBOLS][4][2],
                       const float half_energies[JTTY_DATA_SYMBOLS][4],
                       uint64_t *payload);

// MARK: - Transmit

/// Tones for a whole message.
int jtty_message_tones(const uint64_t *payloads, int count,
                       uint8_t tones[JTTY_FRAME_SYMBOLS * JTTY_MAX_FRAMES]);

/// Render tones to real audio at 12 kHz, unit amplitude, tone 0 at `f0` Hz.
/// `out` must hold nsym * JTTY_NSPS samples.
void jtty_render_audio(const uint8_t *tones, int nsym, float f0, float *out);

// MARK: - Receive

typedef struct jtty_receiver jtty_receiver;

/// A frequency band the receiver looks in. The first channel is the
/// operator's receive frequency and is gated more generously.
typedef struct {
    float centre;
    float half_width;
} jtty_channel;

/// An active message whose next frame is expected: the receiver retries the
/// FEC at the remembered sync point if a window otherwise decodes nothing.
typedef struct {
    float frequency;
    float sync_time; // seconds, absolute (same clock as window_start)
} jtty_continuation;

/// A signal already decoded in a later window, to subtract before searching
/// this one again.
typedef struct {
    float frequency;
    float sync_time;
    uint64_t payload;
} jtty_known_signal;

typedef struct {
    uint64_t payload;
    float frequency;   // tone 0, Hz
    float sync_time;   // absolute seconds of the frame start
    float snr;         // dB in 2500 Hz, FT8 convention
    int channel;
    int sync_matches;  // of 13; -1 for a continuation retry
    bool eom;
    bool trailing_sep;
    char text[JTTY_MAX_TEXT + 1];
} jtty_decode;

typedef struct {
    float rx_frequency;
    float rx_tolerance;
    const jtty_channel *extra_channels;
    int extra_channel_count;
    /// Extra channels are clipped to this range.
    float min_frequency;
    float max_frequency;
    const jtty_continuation *continuations;
    int continuation_count;
    const jtty_known_signal *known;  // optional, one or none
    double window_start;             // absolute seconds of samples[0]
} jtty_receive_request;

jtty_receiver *jtty_receiver_create(void);
void jtty_receiver_destroy(jtty_receiver *receiver);

/// What the last call to jtty_receiver_process looked at: peaks tried,
/// peaks whose sync tones checked out, and frames the FEC accepted. Sync
/// hits without decodes mean JTTY-like signals the decoder cannot read;
/// no sync hits mean whatever is on the waterfall is not JTTY.
typedef struct {
    int candidates;
    int sync_hits;
    int decodes;
} jtty_receiver_stats;
jtty_receiver_stats jtty_receiver_last_stats(const jtty_receiver *receiver);

/// Search one window of JTTY_CHUNK_SAMPLES mono float samples at 12 kHz.
/// Returns the number of decodes written to `out` (at most `max_out`).
int jtty_receiver_process(jtty_receiver *receiver, const float *samples,
                          const jtty_receive_request *request,
                          jtty_decode *out, int max_out);

#ifdef __cplusplus
}
#endif

#endif
