// JTTY forward error correction: CRC-12 outer check, rate-1/2 tail-biting
// convolutional code with K=10, and the list decoder that reads it back.
//
// Decoding is a wrap-around Viterbi (WAVA) that keeps the best four paths
// per state, run twice around the circular trellis. Branch metrics are
// energies of coherent sums over blocks of L symbols, so no noise estimate
// is needed. Closed paths (final state equals the remembered start state)
// are pooled, deduplicated, rescored with a clean single pass, and the top
// four hypotheses go to the CRC. Four coherent block lengths are tried in
// turn: 1, 2 and 4 symbols on the complex correlations, then 1 symbol on
// half-symbol energies for signals whose phase will not hold still.
#include "jtty.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define STATES 512
#define STATE_MASK 0x1FF
#define REG_MASK 0x3FF
#define G0 0x277 // octal 1167
#define G1 0x365 // octal 1545
#define CRC_POLY 0x80F
#define RESERVED_BIT 33
#define WIDTH 4
#define HYPOTHESES 4
#define WRAPS 2

const uint8_t jtty_sync_tones[JTTY_SYNC_SYMBOLS] = { 0, 2, 2, 3, 0, 0, 3, 2, 1, 3, 1, 2, 0 };

static int parity(uint32_t v) { return __builtin_popcount(v) & 1; }

/// CRC-12 over an MSB-first bit string of `nbits` bits held in `bits`.
static uint32_t crc12(uint64_t bits, int nbits)
{
    uint32_t reg = 0;
    for (int i = nbits - 1; i >= 0; i--) {
        uint32_t bit = (bits >> i) & 1;
        reg ^= bit << 11;
        if (reg & 0x800) reg = (reg << 1) ^ CRC_POLY;
        else reg <<= 1;
        reg &= 0xFFF;
    }
    return reg;
}

/// The 46 information bits: payload followed by its CRC.
static uint64_t info_bits(uint64_t payload)
{
    return (payload << 12) | crc12(payload, JTTY_PAYLOAD_BITS);
}

static bool crc_valid(uint64_t info46)
{
    return crc12(info46, JTTY_INFO_BITS) == 0;
}

static inline void transition(int state, int bit, int *next, int *tone)
{
    uint32_t reg = (((uint32_t)state << 1) | (uint32_t)bit) & REG_MASK;
    int b0 = parity(reg & G0);
    int b1 = parity(reg & G1);
    *tone = 2 * b0 + (b0 ^ b1);
    *next = (int)(reg & STATE_MASK);
}

void jtty_encode_frame(uint64_t payload, uint8_t tones[JTTY_DATA_SYMBOLS])
{
    uint64_t info = info_bits(payload);
    int state = (int)(info & STATE_MASK); // tail-biting: start where we will end
    for (int t = 0; t < JTTY_INFO_BITS; t++) {
        int bit = (int)((info >> (JTTY_INFO_BITS - 1 - t)) & 1);
        int tone;
        transition(state, bit, &state, &tone);
        tones[t] = (uint8_t)tone;
    }
}

void jtty_frame_tones(uint64_t payload, uint8_t tones[JTTY_FRAME_SYMBOLS])
{
    memcpy(tones, jtty_sync_tones, JTTY_SYNC_SYMBOLS);
    jtty_encode_frame(payload, tones + JTTY_SYNC_SYMBOLS);
}

int jtty_message_tones(const uint64_t *payloads, int count,
                       uint8_t tones[JTTY_FRAME_SYMBOLS * JTTY_MAX_FRAMES])
{
    if (count < 1 || count > JTTY_MAX_FRAMES) return 0;
    for (int i = 0; i < count; i++) {
        jtty_frame_tones(payloads[i], tones + i * JTTY_FRAME_SYMBOLS);
    }
    return count * JTTY_FRAME_SYMBOLS;
}

// MARK: - List decoder

/// Trellis geometry for one coherent block length.
typedef struct {
    int length;              // L
    int branch_count;        // 2^L
    int block_count;
    int block_start[46];     // 0-based symbol index of each block
    int block_length[46];
    int energy_offset[46];
    int energy_count;
    // For every start state and L-bit input word: the end state and the
    // tone sequence as a base-4 word.
    uint16_t next_state[STATES][16];
    uint8_t tone_word[STATES][16];
    // Same for the short final block, if it has fewer than L bits.
    uint16_t tail_next_state[STATES][16];
    uint8_t tail_tone_word[STATES][16];
} plan;

static plan plans[3];
static bool plans_ready = false;

static void build_plan(plan *p, int L)
{
    memset(p, 0, sizeof *p);
    p->length = L;
    p->branch_count = 1 << L;
    p->block_count = (JTTY_INFO_BITS + L - 1) / L;
    int energy = 0;
    for (int b = 0; b < p->block_count; b++) {
        p->block_start[b] = b * L;
        int len = JTTY_INFO_BITS - b * L;
        if (len > L) len = L;
        p->block_length[b] = len;
        p->energy_offset[b] = energy;
        energy += 1 << (2 * len);
    }
    p->energy_count = energy;
    for (int s = 0; s < STATES; s++) {
        for (int w = 0; w < p->branch_count; w++) {
            int state = s, tw = 0;
            for (int i = L - 1; i >= 0; i--) {
                int tone;
                transition(state, (w >> i) & 1, &state, &tone);
                tw = 4 * tw + tone;
            }
            p->next_state[s][w] = (uint16_t)state;
            p->tone_word[s][w] = (uint8_t)tw;
        }
        int tail = p->block_length[p->block_count - 1];
        for (int w = 0; w < (1 << tail); w++) {
            int state = s, tw = 0;
            for (int i = tail - 1; i >= 0; i--) {
                int tone;
                transition(state, (w >> i) & 1, &state, &tone);
                tw = 4 * tw + tone;
            }
            p->tail_next_state[s][w] = (uint16_t)state;
            p->tail_tone_word[s][w] = (uint8_t)tw;
        }
    }
}

static void ensure_plans(void)
{
    if (plans_ready) return;
    build_plan(&plans[0], 1);
    build_plan(&plans[1], 2);
    build_plan(&plans[2], 4);
    plans_ready = true;
}

/// A retained path. `word` holds the information bits decided so far, bit
/// (45 - position) for 0-based position, so the complete word reads as the
/// MSB-first 46-bit integer; `origin` is the state the path started in.
typedef struct {
    double metric;
    uint64_t word;
    int16_t origin;
    bool valid;
} survivor;

static inline bool precedes(const survivor *a, const survivor *b)
{
    if (a->metric > b->metric) return true;
    if (a->metric < b->metric) return false;
    if (a->origin != b->origin) return a->origin < b->origin;
    return a->word < b->word;
}

static void insert_survivor(survivor *list, const survivor *cand, bool dedupe)
{
    if (dedupe) {
        for (int s = 0; s < WIDTH; s++) {
            if (!list[s].valid) continue;
            if (list[s].word == cand->word && list[s].origin == cand->origin) {
                if (cand->metric <= list[s].metric) return;
                for (int i = s; i < WIDTH - 1; i++) list[i] = list[i + 1];
                list[WIDTH - 1].valid = false;
                break;
            }
        }
    }
    int slot = WIDTH;
    for (int s = 0; s < WIDTH; s++) {
        if (!list[s].valid || precedes(cand, &list[s])) {
            slot = s;
            break;
        }
    }
    if (slot >= WIDTH) return;
    for (int s = WIDTH - 1; s > slot; s--) list[s] = list[s - 1];
    list[slot] = *cand;
}

typedef struct {
    uint64_t word;
    int16_t start_state;
    double clean;
    double wava;
    bool crc_ok;
} candidate;

static int compare_candidates(const void *a, const void *b)
{
    const candidate *x = a, *y = b;
    if (x->clean > y->clean) return -1;
    if (x->clean < y->clean) return 1;
    if (x->word != y->word) return x->word < y->word ? -1 : 1;
    if (x->start_state != y->start_state) return x->start_state < y->start_state ? -1 : 1;
    if (x->wava != y->wava) return x->wava > y->wava ? -1 : 1;
    return 0;
}

/// Energies of every tone sequence of every block: |sum of correlations|^2 / L.
static void sequence_energies(const plan *p, const float z[JTTY_DATA_SYMBOLS][4][2], double *energies)
{
    for (int b = 0; b < p->block_count; b++) {
        int len = p->block_length[b];
        int start = p->block_start[b];
        int count = 1 << (2 * len);
        for (int seq = 0; seq < count; seq++) {
            float re = 0, im = 0;
            for (int i = 0; i < len; i++) {
                int tone = (seq >> (2 * (len - 1 - i))) & 3;
                re += z[start + i][tone][0];
                im += z[start + i][tone][1];
            }
            energies[p->energy_offset[b] + seq] = ((double)re * re + (double)im * im) / len;
        }
    }
}

static inline int block_word(uint64_t word, int start, int len)
{
    return (int)((word >> (JTTY_INFO_BITS - start - len)) & ((1u << len) - 1));
}

static inline uint64_t block_identity(int w, int start, int len)
{
    return (uint64_t)w << (JTTY_INFO_BITS - start - len);
}

static double clean_score(const plan *p, const double *energies, uint64_t word, bool *closed)
{
    int start_state = (int)(word & STATE_MASK);
    int state = start_state;
    double metric = 0;
    for (int b = 0; b < p->block_count; b++) {
        int len = p->block_length[b];
        int w = block_word(word, p->block_start[b], len);
        bool tail = len < p->length;
        int tw = tail ? p->tail_tone_word[state][w] : p->tone_word[state][w];
        metric += energies[p->energy_offset[b] + tw];
        state = tail ? p->tail_next_state[state][w] : p->next_state[state][w];
    }
    *closed = state == start_state;
    return metric;
}

/// One rung of the ladder: list-WAVA at block length `p->length`. Returns
/// the number of hypotheses written.
static int list_wava(const plan *p, const float z[JTTY_DATA_SYMBOLS][4][2], candidate *hyps)
{
    static double energies[16 * 256 + 64];
    static survivor prev[STATES][WIDTH], curr[STATES][WIDTH];
    static candidate pool[STATES * WIDTH];

    sequence_energies(p, z, energies);
    memset(prev, 0, sizeof prev);
    for (int s = 0; s < STATES; s++) {
        prev[s][0].valid = true;
        prev[s][0].metric = 0;
        prev[s][0].origin = (int16_t)s;
        prev[s][0].word = 0;
    }

    for (int wrap = 0; wrap < WRAPS; wrap++) {
        // Each wrap re-reads the frame from its first symbol; the path keeps
        // its metric and its origin but starts a fresh word.
        for (int s = 0; s < STATES; s++) {
            for (int r = 0; r < WIDTH; r++) {
                if (prev[s][r].valid) {
                    prev[s][r].origin = (int16_t)s;
                    prev[s][r].word = 0;
                }
            }
        }
        for (int b = 0; b < p->block_count; b++) {
            int len = p->block_length[b];
            int start = p->block_start[b];
            int bc = 1 << len;
            int stride = STATES / bc;
            bool tail = len < p->length;
            // Position 33 (1-based) is reserved zero; drop branches that set it.
            bool prune_block = start < RESERVED_BIT && start + len >= RESERVED_BIT;
            const double *e = energies + p->energy_offset[b];
            for (int end = 0; end < STATES; end++) {
                survivor selected[WIDTH];
                memset(selected, 0, sizeof selected);
                int w = end & (bc - 1);
                bool pruned = prune_block && ((w >> (start + len - RESERVED_BIT)) & 1);
                if (!pruned) {
                    uint64_t identity = block_identity(w, start, len);
                    for (int s = end >> len; s < STATES; s += stride) {
                        int tw = tail ? p->tail_tone_word[s][w] : p->tone_word[s][w];
                        double bm = e[tw];
                        for (int r = 0; r < WIDTH; r++) {
                            const survivor *ps = &prev[s][r];
                            if (!ps->valid) continue;
                            double metric = ps->metric + bm;
                            if (selected[WIDTH - 1].valid && metric < selected[WIDTH - 1].metric) break;
                            survivor ext = *ps;
                            ext.metric = metric;
                            ext.word |= identity;
                            insert_survivor(selected, &ext, b == 0);
                        }
                    }
                }
                memcpy(curr[end], selected, sizeof selected);
            }
            memcpy(prev, curr, sizeof prev);
        }
    }

    // Pool the closed paths, one entry per distinct word.
    int pool_count = 0;
    for (int s = 0; s < STATES; s++) {
        for (int r = 0; r < WIDTH; r++) {
            const survivor *sv = &prev[s][r];
            if (!sv->valid || sv->origin != s) continue;
            int found = -1;
            for (int i = 0; i < pool_count; i++) {
                if (pool[i].word == sv->word) { found = i; break; }
            }
            if (found >= 0) {
                if (sv->metric > pool[found].wava ||
                    (!(sv->metric < pool[found].wava) && s < pool[found].start_state)) {
                    pool[found].wava = sv->metric;
                    pool[found].start_state = (int16_t)s;
                }
                continue;
            }
            candidate *c = &pool[pool_count++];
            c->word = sv->word;
            c->start_state = (int16_t)s;
            c->wava = sv->metric;
            bool closed;
            c->clean = clean_score(p, energies, sv->word, &closed);
            c->crc_ok = crc_valid(sv->word);
        }
    }
    qsort(pool, (size_t)pool_count, sizeof pool[0], compare_candidates);
    int count = pool_count < HYPOTHESES ? pool_count : HYPOTHESES;
    memcpy(hyps, pool, (size_t)count * sizeof pool[0]);
    return count;
}

static bool admit(const candidate *hyps, int count, uint64_t *payload)
{
    for (int i = 0; i < count; i++) {
        if (!hyps[i].crc_ok) continue;
        uint64_t p = hyps[i].word >> 12;
        // The all-zero word is the protocol's invalid sentinel; do not spend
        // the false-accept budget past it.
        if (p == 0) return false;
        *payload = p;
        return true;
    }
    return false;
}

bool jtty_decode_frame(const float correlations[JTTY_DATA_SYMBOLS][4][2],
                       const float half_energies[JTTY_DATA_SYMBOLS][4],
                       uint64_t *payload)
{
    ensure_plans();
    candidate hyps[HYPOTHESES];
    for (int rung = 0; rung < 3; rung++) {
        int count = list_wava(&plans[rung], correlations, hyps);
        if (admit(hyps, count, payload)) return true;
    }
    // Half-symbol energies have no phase, so only the one-symbol rung applies.
    float z[JTTY_DATA_SYMBOLS][4][2];
    for (int s = 0; s < JTTY_DATA_SYMBOLS; s++) {
        for (int t = 0; t < 4; t++) {
            z[s][t][0] = half_energies[s][t];
            z[s][t][1] = 0;
        }
    }
    int count = list_wava(&plans[0], z, hyps);
    return admit(hyps, count, payload);
}
