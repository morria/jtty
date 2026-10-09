// JTTY source codec: the 32-bit grammar word, its rendering, and the
// minimum-frame packer for free text.
#include "jtty.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const char jtty_alphabet[65] =
    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ +-./?!\"#$%,&*()_'=[]{}<>|:;";

const char *const jtty_control_phrases[JTTY_CONTROL_COUNT] = {
    "AGN?", "CALL?", "AGN CALL", "NR?", "AGN NR", "EXCH?", "STATE?",
    "SECTION?", "ZONE?", "GRID?", "RPRT?", "QSL TU", "TU", "QRZ?",
    "QSO B4", "WAIT", "NIL?", "OK?",
};

const char *const jtty_arrl_sections[87] = {
    "",
    "AB", "AK", "AL", "AR", "AZ", "BC", "CO", "CT", "DE", "EB",
    "EMA", "ENY", "EPA", "EWA", "GA", "GH", "IA", "ID", "IL", "IN",
    "KS", "KY", "LA", "LAX", "NS", "MB", "MDC", "ME", "MI", "MN",
    "MO", "MS", "MT", "NC", "ND", "NE", "NFL", "NH", "NL", "NLI",
    "NM", "NNJ", "NNY", "TER", "NTX", "NV", "OH", "OK", "ONE", "ONN",
    "ONS", "OR", "ORG", "PAC", "PR", "QC", "RI", "SB", "SC", "SCV",
    "SD", "SDG", "SF", "SFL", "SJV", "SK", "SNJ", "STX", "SV", "TN",
    "UT", "VA", "VI", "VT", "WCF", "WI", "WMA", "WNY", "WPA", "WTX",
    "WV", "WWA", "WY", "DX", "PE", "NB",
};

int jtty_section_index(const char *section)
{
    for (int i = 1; i <= 86; i++) {
        if (strcmp(jtty_arrl_sections[i], section) == 0) return i;
    }
    return 0;
}

static int alphabet_index(char c)
{
    const char *p = c ? strchr(jtty_alphabet, c) : NULL;
    return p ? (int)(p - jtty_alphabet) : -1;
}

// MARK: - Callsigns

// The 28-bit callsign field, as the FT8 family packs a standard call:
// a token space, 22 bits of hashes, then the standard calls.
#define NTOKENS 2063592
#define MAX22 4194304

static bool is_digit_c(char c) { return c >= '0' && c <= '9'; }
static bool is_letter_c(char c) { return c >= 'A' && c <= 'Z'; }

/// The syntax check the WSJT family applies to a putative callsign: a
/// letter in the first two characters, a digit in the second or third, then
/// one to three letters.
static bool callsign_shape_ok(const char *w)
{
    size_t n = strlen(w);
    if (n == 0 || n > 6) return false;
    if (strchr(w, '/')) return false;
    if (!is_letter_c(w[0]) && !is_letter_c(w[1])) return false;
    if (w[0] == 'Q') return false;
    int area = 0;
    if (n > 1 && is_digit_c(w[1])) area = 1;
    if (n > 2 && is_digit_c(w[2])) area = 2;
    if (area == 0) return false;
    if ((size_t)area == n - 1) return false;
    int suffix = 0;
    for (size_t i = area + 1; i < n; i++) {
        if (!is_letter_c(w[i])) return false;
        suffix++;
    }
    return suffix >= 1 && suffix <= 3;
}

static int table_index(const char *table, char c)
{
    const char *p = strchr(table, c);
    return (p && c) ? (int)(p - table) : -1;
}

static const char A1[] = " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
static const char A2[] = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
static const char A3[] = "0123456789";
static const char A4[] = " ABCDEFGHIJKLMNOPQRSTUVWXYZ";

static bool pack28(const char *call, uint32_t *n28)
{
    if (!callsign_shape_ok(call)) return false;
    size_t n = strlen(call);
    int area = is_digit_c(call[2]) && n > 2 ? 2 : 1;
    char c6[7] = "      ";
    if (area == 1) {
        memcpy(c6 + 1, call, n < 5 ? n : 5);
    } else {
        memcpy(c6, call, n < 6 ? n : 6);
    }
    int i1 = table_index(A1, c6[0]);
    int i2 = table_index(A2, c6[1]);
    int i3 = table_index(A3, c6[2]);
    int i4 = table_index(A4, c6[3]);
    int i5 = table_index(A4, c6[4]);
    int i6 = table_index(A4, c6[5]);
    if (i1 < 0 || i2 < 0 || i3 < 0 || i4 < 0 || i5 < 0 || i6 < 0) return false;
    uint32_t v = (uint32_t)i1;
    v = v * 36 + i2;
    v = v * 10 + i3;
    v = v * 27 + i4;
    v = v * 27 + i5;
    v = v * 27 + i6;
    *n28 = (v + NTOKENS + MAX22) & ((1u << 28) - 1);
    return true;
}

static bool unpack28(uint32_t n28, char out[14])
{
    if (n28 < NTOKENS + MAX22) return false;
    uint32_t n = n28 - NTOKENS - MAX22;
    char c[7];
    c[6] = 0;
    c[5] = A4[n % 27]; n /= 27;
    c[4] = A4[n % 27]; n /= 27;
    c[3] = A4[n % 27]; n /= 27;
    c[2] = A3[n % 10]; n /= 10;
    c[1] = A2[n % 36]; n /= 36;
    if (n >= 37) return false;
    c[0] = A1[n];
    // Left-justify and drop trailing spaces; an interior space is invalid.
    const char *start = c[0] == ' ' ? c + 1 : c;
    size_t len = strlen(start);
    while (len > 0 && start[len - 1] == ' ') len--;
    if (len == 0 || len > 13) return false;
    memcpy(out, start, len);
    out[len] = 0;
    if (strchr(out, ' ')) return false;
    return callsign_shape_ok(out);
}

bool jtty_is_standard_call(const char *callsign)
{
    if (!callsign) return false;
    size_t n = strlen(callsign);
    if (n == 0 || n > 13) return false;
    for (size_t i = 0; i < n; i++) {
        if (!is_digit_c(callsign[i]) && !is_letter_c(callsign[i])) return false;
    }
    if (!callsign_shape_ok(callsign)) return false;
    uint32_t n28;
    char back[14];
    if (!pack28(callsign, &n28)) return false;
    if (!unpack28(n28, back)) return false;
    return strcmp(back, callsign) == 0;
}

// MARK: - Fields

static bool valid_role(int role) { return role == 0 || role == 1; }

static bool valid_number(int kind, int value)
{
    if (kind < 0 || kind > 7 || value < 0 || value > 131071) return false;
    if (kind == JTTY_NUM_CQ_ZONE) return value >= 1 && value <= 40;
    if (kind == JTTY_NUM_ITU_ZONE) return value >= 1 && value <= 90;
    if (kind == JTTY_NUM_LICENSE_YEAR) return value <= 9999;
    return true;
}

static bool pack_base36(const char *token, uint32_t *value)
{
    size_t n = strlen(token);
    if (n != 2 && n != 3) return false;
    uint32_t v = 0;
    for (size_t i = 0; i < n; i++) {
        int d = table_index(A2, token[i]);
        if (d < 0) return false;
        v = v * 36 + d;
    }
    if (n == 3 && v < 36 * 36) return false;
    *value = v;
    return true;
}

static void unpack_base36(uint32_t value, int n, char *token)
{
    for (int i = n - 1; i >= 0; i--) {
        token[i] = A2[value % 36];
        value /= 36;
    }
    token[n] = 0;
}

static bool grid4_to_index(const char *grid, int *index)
{
    if (strlen(grid) != 4) return false;
    int a = grid[0] - 'A', b = grid[1] - 'A', c = grid[2] - '0', d = grid[3] - '0';
    if (a < 0 || a >= 18 || b < 0 || b >= 18 || c < 0 || c >= 10 || d < 0 || d >= 10) return false;
    *index = ((a * 18 + b) * 10 + c) * 10 + d;
    return true;
}

static void index_to_grid4(int index, char *grid)
{
    int d = index % 10; index /= 10;
    int c = index % 10; index /= 10;
    int b = index % 18;
    int a = index / 18;
    grid[0] = (char)('A' + a);
    grid[1] = (char)('A' + b);
    grid[2] = (char)('0' + c);
    grid[3] = (char)('0' + d);
    grid[4] = 0;
}

static uint64_t finish_struct(uint64_t body, int family)
{
    return 4 * (8 * body + (uint64_t)family) + 2;
}

static uint64_t bits_of(uint64_t v, int pos, int len)
{
    return (v >> pos) & ((1ull << len) - 1);
}

// MARK: - Pack

bool jtty_pack_atom(const jtty_atom *atom, bool eom, uint64_t *payload)
{
    uint64_t n32 = 0;
    uint32_t token;
    switch (atom->kind) {
    case JTTY_ATOM_CALL: {
        if (atom->subtype < 0 || atom->subtype > 5) return false;
        if (!jtty_is_standard_call(atom->text)) return false;
        uint32_t n28;
        if (!pack28(atom->text, &n28)) return false;
        int i2 = atom->subtype <= 3 ? 0 : 1;
        int n2 = atom->subtype <= 3 ? atom->subtype : atom->subtype - 4;
        n32 = ((uint64_t)n28 << 4) + 4 * (uint64_t)n2 + (uint64_t)i2;
        break;
    }
    case JTTY_ATOM_EXCH_NUM: {
        if (!valid_role(atom->role) || !valid_number(atom->subtype, atom->value)) return false;
        uint64_t body = ((uint64_t)atom->role << 26) | ((uint64_t)atom->subtype << 22) |
                        ((uint64_t)atom->value << 5);
        n32 = finish_struct(body, 0);
        break;
    }
    case JTTY_ATOM_EXCH_LOC: {
        if (!valid_role(atom->role) || atom->subtype < 0 || atom->subtype > 4) return false;
        size_t n = strlen(atom->text);
        if (n != 2 && n != 3) return false;
        if (!pack_base36(atom->text, &token)) return false;
        uint64_t body = ((uint64_t)atom->role << 26) | ((uint64_t)atom->subtype << 22) |
                        ((uint64_t)(n - 2) << 21) | ((uint64_t)token << 5);
        n32 = finish_struct(body, 1);
        break;
    }
    case JTTY_ATOM_EXCH_PAIR: {
        uint64_t pair;
        if (atom->subtype == JTTY_PAIR_ZONE_LOC3) {
            if (atom->value < 1 || atom->value > 40) return false;
            size_t n = strlen(atom->text);
            if (n != 2 && n != 3) return false;
            if (!pack_base36(atom->text, &token)) return false;
            pair = ((uint64_t)atom->value << 17) | ((uint64_t)(n - 2) << 16) | token;
        } else if (atom->subtype == JTTY_PAIR_CLASS_SECTION) {
            if (atom->value < 1 || atom->value > 32) return false;
            if (atom->value2 < 1 || atom->value2 > 86 || strlen(atom->text) != 1) return false;
            int cls = atom->text[0] - 'A';
            if (cls < 0 || cls > 5) return false;
            pair = ((uint64_t)atom->value << 17) | ((uint64_t)cls << 14) | ((uint64_t)atom->value2 << 7);
        } else {
            return false;
        }
        uint64_t body = ((uint64_t)atom->subtype << 24) | (pair << 1);
        n32 = finish_struct(body, 2);
        break;
    }
    case JTTY_ATOM_EXCH_NUM_TIME: {
        if (!valid_role(atom->role) || atom->value < 0 || atom->value > 16383) return false;
        if (atom->value2 < 0 || atom->value2 > 1439) return false;
        uint64_t body = ((uint64_t)atom->role << 26) | ((uint64_t)atom->value << 12) |
                        ((uint64_t)atom->value2 << 1);
        n32 = finish_struct(body, 3);
        break;
    }
    case JTTY_ATOM_CONTROL: {
        if (atom->subtype < 0 || atom->subtype >= JTTY_CONTROL_COUNT) return false;
        uint64_t body = ((uint64_t)0 << 23) | ((uint64_t)atom->subtype << 16);
        n32 = finish_struct(body, 4);
        break;
    }
    case JTTY_ATOM_GRID4: {
        if (!valid_role(atom->role)) return false;
        int index;
        if (!grid4_to_index(atom->text, &index)) return false;
        uint64_t data = ((uint64_t)atom->role << 22) | ((uint64_t)index << 7);
        uint64_t body = ((uint64_t)1 << 23) | data;
        n32 = finish_struct(body, 4);
        break;
    }
    case JTTY_ATOM_TEXT5: {
        uint64_t top30 = 0;
        for (int i = 0; i < 5; i++) {
            // Short text is padded with spaces, which is index 36.
            char c = i < (int)strlen(atom->text) ? atom->text[i] : ' ';
            int idx = alphabet_index(c);
            if (idx < 0) return false;
            top30 = 64 * top30 + (uint64_t)idx;
        }
        n32 = 4 * top30 + 3;
        break;
    }
    default:
        return false;
    }
    *payload = (n32 << 2) | (eom ? 1 : 0);
    return true;
}

// MARK: - Unpack

bool jtty_unpack_atom(uint64_t payload, jtty_atom *atom, bool *eom)
{
    memset(atom, 0, sizeof *atom);
    atom->kind = -1;
    if (eom) *eom = false;
    if (payload >> 34) return false;
    if (payload & 2) return false; // reserved bit 33
    uint64_t n32 = payload >> 2;
    if (n32 == 0) return false;
    int i2 = (int)(n32 & 3);
    uint64_t top30 = n32 >> 2;
    switch (i2) {
    case 0:
    case 1: {
        uint32_t n28 = (uint32_t)(n32 >> 4);
        int n2 = (int)((n32 >> 2) & 3);
        if (i2 == 1 && n2 > 1) return false;
        char call[14];
        if (!unpack28(n28, call)) return false;
        if (!jtty_is_standard_call(call)) return false;
        atom->kind = JTTY_ATOM_CALL;
        atom->subtype = i2 == 0 ? n2 : n2 + 4;
        strcpy(atom->text, call);
        break;
    }
    case 2: {
        int family = (int)(top30 & 7);
        uint64_t body = top30 >> 3;
        switch (family) {
        case 0: {
            atom->kind = JTTY_ATOM_EXCH_NUM;
            atom->role = (int)bits_of(body, 26, 1);
            atom->subtype = (int)bits_of(body, 22, 4);
            atom->value = (int)bits_of(body, 5, 17);
            if (bits_of(body, 0, 5) != 0 || !valid_number(atom->subtype, atom->value)) return false;
            break;
        }
        case 1: {
            atom->kind = JTTY_ATOM_EXCH_LOC;
            atom->role = (int)bits_of(body, 26, 1);
            atom->subtype = (int)bits_of(body, 22, 4);
            int n = (int)bits_of(body, 21, 1) + 2;
            uint32_t token = (uint32_t)bits_of(body, 5, 16);
            if (bits_of(body, 0, 5) != 0 || atom->subtype > 4) return false;
            uint32_t limit = n == 2 ? 36 * 36 : 36 * 36 * 36;
            if (token >= limit) return false;
            if (n == 3 && token < 36 * 36) return false;
            unpack_base36(token, n, atom->text);
            break;
        }
        case 2: {
            atom->kind = JTTY_ATOM_EXCH_PAIR;
            atom->subtype = (int)bits_of(body, 24, 3);
            uint64_t pair = bits_of(body, 1, 23);
            if (bits_of(body, 0, 1) != 0) return false;
            if (atom->subtype == JTTY_PAIR_ZONE_LOC3) {
                atom->value = (int)bits_of(pair, 17, 6);
                int n = (int)bits_of(pair, 16, 1) + 2;
                uint32_t token = (uint32_t)bits_of(pair, 0, 16);
                uint32_t limit = n == 2 ? 36 * 36 : 36 * 36 * 36;
                if (atom->value < 1 || atom->value > 40 || token >= limit) return false;
                if (n == 3 && token < 36 * 36) return false;
                unpack_base36(token, n, atom->text);
            } else if (atom->subtype == JTTY_PAIR_CLASS_SECTION) {
                atom->value = (int)bits_of(pair, 17, 6);
                int cls = (int)bits_of(pair, 14, 3);
                atom->value2 = (int)bits_of(pair, 7, 7);
                if (bits_of(pair, 0, 7) != 0) return false;
                if (atom->value < 1 || atom->value > 32 || cls > 5) return false;
                if (atom->value2 < 1 || atom->value2 > 86) return false;
                atom->text[0] = (char)('A' + cls);
                atom->text[1] = 0;
            } else {
                return false;
            }
            break;
        }
        case 3: {
            atom->kind = JTTY_ATOM_EXCH_NUM_TIME;
            atom->role = (int)bits_of(body, 26, 1);
            atom->value = (int)bits_of(body, 12, 14);
            atom->value2 = (int)bits_of(body, 1, 11);
            if (bits_of(body, 0, 1) != 0 || atom->value2 > 1439) return false;
            break;
        }
        case 4: {
            int subtype = (int)bits_of(body, 23, 4);
            uint64_t data = bits_of(body, 0, 23);
            if (subtype == 0) {
                atom->kind = JTTY_ATOM_CONTROL;
                atom->subtype = (int)bits_of(data, 16, 7);
                if (bits_of(data, 0, 16) != 0 || atom->subtype >= JTTY_CONTROL_COUNT) return false;
            } else if (subtype == 1) {
                atom->kind = JTTY_ATOM_GRID4;
                atom->role = (int)bits_of(data, 22, 1);
                int index = (int)bits_of(data, 7, 15);
                if (bits_of(data, 0, 7) != 0 || index >= 32400) return false;
                index_to_grid4(index, atom->text);
            } else {
                return false;
            }
            break;
        }
        default:
            return false;
        }
        break;
    }
    case 3: {
        atom->kind = JTTY_ATOM_TEXT5;
        for (int i = 0; i < 5; i++) {
            atom->text[i] = jtty_alphabet[(top30 >> (6 * (4 - i))) & 63];
        }
        atom->text[5] = 0;
        break;
    }
    }
    if (eom) *eom = (payload & 1) != 0;
    return true;
}

// MARK: - Render

static void render_number(int kind, int value, char *out)
{
    switch (kind) {
    case JTTY_NUM_SERIAL:
        sprintf(out, value < 1000 ? "%03d" : "%d", value);
        break;
    case JTTY_NUM_CQ_ZONE:
    case JTTY_NUM_ITU_ZONE:
    case JTTY_NUM_CHECK:
        sprintf(out, value < 100 ? "%02d" : "%d", value);
        break;
    case JTTY_NUM_LICENSE_YEAR:
        sprintf(out, "%04d", value);
        break;
    default:
        sprintf(out, "%d", value);
    }
}

static void render_role(int role, const char *field, char *out)
{
    if (role == JTTY_ROLE_FULL) {
        snprintf(out, JTTY_MAX_TEXT + 1, "599 %s", field);
    } else {
        snprintf(out, JTTY_MAX_TEXT + 1, "%s", field);
    }
}

bool jtty_render_atom(const jtty_atom *atom, char text[JTTY_MAX_TEXT + 1])
{
    char first[32], second[32];
    text[0] = 0;
    switch (atom->kind) {
    case JTTY_ATOM_CALL:
        switch (atom->subtype) {
        case JTTY_CALL_CQ: snprintf(text, 81, "CQ %s CQ", atom->text); break;
        case JTTY_CALL_CALL: snprintf(text, 81, "%s", atom->text); break;
        case JTTY_CALL_TU_CQ: snprintf(text, 81, "TU %s CQ", atom->text); break;
        case JTTY_CALL_CALL_TU: snprintf(text, 81, "%s TU", atom->text); break;
        case JTTY_CALL_AGN: snprintf(text, 81, "%s AGN?", atom->text); break;
        case JTTY_CALL_TU_NOW: snprintf(text, 81, "TU NOW %s", atom->text); break;
        default: return false;
        }
        return true;
    case JTTY_ATOM_EXCH_NUM:
        if (!valid_role(atom->role) || !valid_number(atom->subtype, atom->value)) return false;
        render_number(atom->subtype, atom->value, first);
        render_role(atom->role, first, text);
        return true;
    case JTTY_ATOM_EXCH_LOC:
        if (atom->subtype < 0 || atom->subtype > 4) return false;
        render_role(atom->role, atom->text, text);
        return true;
    case JTTY_ATOM_EXCH_PAIR:
        if (atom->subtype == JTTY_PAIR_ZONE_LOC3) {
            snprintf(text, 81, "599 %02d %s", atom->value, atom->text);
            return true;
        }
        if (atom->subtype == JTTY_PAIR_CLASS_SECTION) {
            if (atom->value2 < 1 || atom->value2 > 86) return false;
            snprintf(text, 81, "%d%c %s", atom->value, atom->text[0], jtty_arrl_sections[atom->value2]);
            return true;
        }
        return false;
    case JTTY_ATOM_EXCH_NUM_TIME:
        if (!valid_role(atom->role) || atom->value < 0 || atom->value > 16383 ||
            atom->value2 < 0 || atom->value2 > 1439) return false;
        render_number(JTTY_NUM_SERIAL, atom->value, first);
        sprintf(second, "%s %02d%02d", first, atom->value2 / 60, atom->value2 % 60);
        render_role(atom->role, second, text);
        return true;
    case JTTY_ATOM_CONTROL:
        if (atom->subtype < 0 || atom->subtype >= JTTY_CONTROL_COUNT) return false;
        snprintf(text, 81, "%s", jtty_control_phrases[atom->subtype]);
        return true;
    case JTTY_ATOM_GRID4:
        render_role(atom->role, atom->text, text);
        return true;
    case JTTY_ATOM_TEXT5:
        snprintf(text, 81, "%.5s", atom->text);
        return true;
    default:
        return false;
    }
}

bool jtty_unpack_frame(uint64_t payload, char text[JTTY_MAX_TEXT + 1],
                       bool *trailing_sep, bool *eom)
{
    jtty_atom atom;
    bool last;
    text[0] = 0;
    if (trailing_sep) *trailing_sep = false;
    if (eom) *eom = false;
    if (!jtty_unpack_atom(payload, &atom, &last)) return false;
    if (!jtty_render_atom(&atom, text)) return false;
    if (atom.kind == JTTY_ATOM_TEXT5) {
        for (int i = 0; i < 5; i++) {
            if (text[i] == ' ') text[i] = '~';
        }
    } else if (trailing_sep) {
        *trailing_sep = true;
    }
    if (eom) *eom = last;
    return true;
}

// MARK: - Text

void jtty_normalize(const char *input, char output[JTTY_MAX_TEXT + 1])
{
    int j = 0;
    bool last_space = true;
    for (int i = 0; i < JTTY_MAX_TEXT && input[i]; i++) {
        char c = input[i];
        if (c == '~') c = ' ';
        if (c >= 'a' && c <= 'z') c = (char)(c - 32);
        if (alphabet_index(c) < 0) c = '#';
        if (c == ' ') {
            if (last_space) continue;
            output[j++] = ' ';
            last_space = true;
        } else {
            output[j++] = c;
            last_space = false;
        }
    }
    while (j > 0 && output[j - 1] == ' ') j--;
    output[j] = 0;
}

static bool decimal_value(const char *text, int *value)
{
    size_t n = strlen(text);
    if (n < 1 || n > 6) return false;
    int v = 0;
    for (size_t i = 0; i < n; i++) {
        if (!is_digit_c(text[i])) return false;
        v = 10 * v + (text[i] - '0');
    }
    *value = v;
    return v <= 131071;
}

static jtty_atom make_atom(int kind, int subtype, int role, int value, int value2, const char *text)
{
    jtty_atom a;
    memset(&a, 0, sizeof a);
    a.kind = kind;
    a.subtype = subtype;
    a.role = role;
    a.value = value;
    a.value2 = value2;
    if (text) snprintf(a.text, sizeof a.text, "%s", text);
    return a;
}

/// Under RTTY Roundup, a number after a complete "599" is a serial and is
/// spelt the way the SERIAL atom renders it.
static bool normalize_serials(char msg[JTTY_MAX_TEXT + 1])
{
    char result[2 * JTTY_MAX_TEXT + 2] = "";
    char work[JTTY_MAX_TEXT + 1];
    strcpy(work, msg);
    char *tokens[JTTY_MAX_TEXT];
    int count = 0;
    for (char *p = strtok(work, " "); p; p = strtok(NULL, " ")) tokens[count++] = p;
    int i = 0;
    while (i < count) {
        char rendered[JTTY_MAX_TEXT + 1];
        int value;
        if (strcmp(tokens[i], "599") == 0 && i + 1 < count && decimal_value(tokens[i + 1], &value)) {
            jtty_atom a = make_atom(JTTY_ATOM_EXCH_NUM, JTTY_NUM_SERIAL, JTTY_ROLE_FULL, value, 0, NULL);
            if (!jtty_render_atom(&a, rendered)) return false;
            i += 2;
        } else {
            strcpy(rendered, tokens[i]);
            i += 1;
        }
        if (result[0]) strcat(result, " ");
        strcat(result, rendered);
        if (strlen(result) > JTTY_MAX_TEXT) return false;
    }
    strcpy(msg, result);
    return true;
}

typedef struct {
    const char *msg;
    int n;
    int profile;
    int ipos;           // 1-based current position
    int dp[JTTY_MAX_TEXT + 2];
    int successor[JTTY_MAX_TEXT + 2];
    jtty_atom choice[JTTY_MAX_TEXT + 2];
} packer;

#define INF 999

static void consider(packer *p, const jtty_atom *atom, int next)
{
    int ipos = p->ipos;
    int cost = 1 + p->dp[next];
    if (cost > JTTY_MAX_FRAMES || cost > p->dp[ipos]) return;
    int rank = atom->kind == JTTY_ATOM_TEXT5 ? 1 : 0;
    int best_rank = p->choice[ipos].kind == JTTY_ATOM_TEXT5 ? 1 : 0;
    int key = 100 * atom->kind + 2 * atom->subtype + atom->role;
    int best_key = 100 * p->choice[ipos].kind + 2 * p->choice[ipos].subtype + p->choice[ipos].role;
    if (cost == p->dp[ipos]) {
        if (rank > best_rank) return;
        if (rank == best_rank) {
            if (next < p->successor[ipos]) return;
            if (next == p->successor[ipos] && key >= best_key) return;
        }
    }
    p->dp[ipos] = cost;
    p->successor[ipos] = next;
    p->choice[ipos] = *atom;
}

/// Offer a structured atom at the current position: it must round-trip
/// through the wire format and render exactly as the text there.
static void offer(packer *p, jtty_atom atom)
{
    uint64_t frame;
    jtty_atom decoded;
    bool eom;
    char rendered[JTTY_MAX_TEXT + 1];
    if (!jtty_pack_atom(&atom, false, &frame)) return;
    if (!jtty_unpack_atom(frame, &decoded, &eom)) return;
    if (!jtty_render_atom(&decoded, rendered)) return;
    int length = (int)strlen(rendered);
    if (length == 0) return;
    int last = p->ipos + length - 1;
    if (last > p->n) return;
    if (strncmp(p->msg + p->ipos - 1, rendered, (size_t)length) != 0) return;
    int next = p->n + 1;
    if (last < p->n) {
        if (p->msg[last] != ' ') return;
        next = last + 2;
    }
    consider(p, &atom, next);
}

static void try_compact(packer *p)
{
    char words[3][JTTY_MAX_TEXT + 1];
    int nwords = 0;
    int first = p->ipos;
    for (int j = 0; j < 3; j++) {
        if (first > p->n) break;
        const char *start = p->msg + first - 1;
        const char *space = strchr(start, ' ');
        int len = space ? (int)(space - start) : (int)strlen(start);
        memcpy(words[j], start, (size_t)len);
        words[j][len] = 0;
        nwords = j + 1;
        first += len + 1;
    }
    for (int j = 1; j < 3; j++) if (j >= nwords) words[j][0] = 0;

    for (int j = 0; j < nwords; j++) {
        if (strlen(words[j]) > 13) continue;
        for (int action = JTTY_CALL_CQ; action <= JTTY_CALL_TU_NOW; action++) {
            offer(p, make_atom(JTTY_ATOM_CALL, action, 0, 0, 0, words[j]));
        }
    }
    for (int j = 0; j < JTTY_CONTROL_COUNT; j++) {
        offer(p, make_atom(JTTY_ATOM_CONTROL, j, 0, 0, 0, NULL));
    }

    for (int role = JTTY_ROLE_FIELD_ONLY; role <= JTTY_ROLE_FULL; role++) {
        int field = 0;
        if (role == JTTY_ROLE_FULL) {
            if (strcmp(words[0], "599") != 0 || nwords < 2) continue;
            field = 1;
        }
        int length = (int)strlen(words[field]);
        int value;
        bool numeric = decimal_value(words[field], &value);
        if (numeric) offer(p, make_atom(JTTY_ATOM_EXCH_NUM, JTTY_NUM_GENERIC, role, value, 0, NULL));
        if (numeric && role == JTTY_ROLE_FULL && p->profile == JTTY_PROFILE_RTTY_ROUNDUP) {
            offer(p, make_atom(JTTY_ATOM_EXCH_NUM, JTTY_NUM_SERIAL, role, value, 0, NULL));
        }
        if (length == 4) offer(p, make_atom(JTTY_ATOM_GRID4, 0, role, 0, 0, words[field]));
        if (role != JTTY_ROLE_FULL || length < 2 || length > 3) continue;
        if (strpbrk(words[field], "ABCDEFGHIJKLMNOPQRSTUVWXYZ") == NULL) continue;
        offer(p, make_atom(JTTY_ATOM_EXCH_LOC, JTTY_LOC_QTH, role, 0, 0, words[field]));
        if (p->profile == JTTY_PROFILE_RTTY_ROUNDUP) {
            offer(p, make_atom(JTTY_ATOM_EXCH_LOC, JTTY_LOC_STATE_PROVINCE, role, 0, 0, words[field]));
        }
    }

    int length = (int)strlen(words[0]);
    if (nwords < 2 || length < 2 || length > 3) return;
    char count_text[4];
    memcpy(count_text, words[0], (size_t)(length - 1));
    count_text[length - 1] = 0;
    int value;
    if (!decimal_value(count_text, &value)) return;
    int section = jtty_section_index(words[1]);
    char cls[2] = { words[0][length - 1], 0 };
    offer(p, make_atom(JTTY_ATOM_EXCH_PAIR, JTTY_PAIR_CLASS_SECTION, 0, value, section, cls));
}

int jtty_pack_text(const char *text, int profile,
                   uint64_t payloads[JTTY_MAX_FRAMES],
                   char normalized[JTTY_MAX_TEXT + 1])
{
    static packer p; // large; the packer is not re-entrant
    char msg[JTTY_MAX_TEXT + 1];
    jtty_normalize(text, msg);
    if (profile < JTTY_PROFILE_UNKNOWN || profile > JTTY_PROFILE_RTTY_ROUNDUP) return -1;
    if (profile == JTTY_PROFILE_RTTY_ROUNDUP && !normalize_serials(msg)) return -1;
    if (normalized) strcpy(normalized, msg);
    int n = (int)strlen(msg);
    if (n == 0) return 0;

    memset(&p, 0, sizeof p);
    p.msg = msg;
    p.n = n;
    p.profile = profile;
    for (int i = 0; i <= n + 1; i++) {
        p.dp[i] = INF;
        p.choice[i].kind = -1;
    }
    p.dp[n + 1] = 0;
    for (int ipos = n; ipos >= 1; ipos--) {
        p.ipos = ipos;
        int inext = ipos + 5 < n + 1 ? ipos + 5 : n + 1;
        char piece[6];
        int len = inext - ipos;
        memcpy(piece, msg + ipos - 1, (size_t)len);
        piece[len] = 0;
        jtty_atom t5 = make_atom(JTTY_ATOM_TEXT5, 0, 0, 0, 0, piece);
        consider(&p, &t5, inext);
        if (ipos > 1 && msg[ipos - 2] != ' ') continue;
        try_compact(&p);
    }
    if (p.dp[1] > JTTY_MAX_FRAMES) return -1;

    jtty_atom atoms[JTTY_MAX_FRAMES];
    int natoms = 0;
    int ipos = 1;
    while (ipos <= n) {
        if (natoms >= JTTY_MAX_FRAMES) return -1;
        atoms[natoms++] = p.choice[ipos];
        ipos = p.successor[ipos];
    }
    if (!jtty_pack_atoms(atoms, natoms, payloads)) return -1;
    return natoms;
}

bool jtty_pack_atoms(const jtty_atom *atoms, int count,
                     uint64_t payloads[JTTY_MAX_FRAMES])
{
    if (count < 1 || count > JTTY_MAX_FRAMES) return false;
    for (int i = 0; i < count; i++) {
        if (!jtty_pack_atom(&atoms[i], i == count - 1, &payloads[i])) return false;
    }
    return true;
}
