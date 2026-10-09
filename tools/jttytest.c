// Command-line checks for the modem: golden vectors, text packing,
// loopback through the receiver, and decoding of WAV files.
//
//   clang -O2 -I jttylib/Sources/CJTTY/include jttylib/Sources/CJTTY/src/*.c \
//       tools/jttytest.c -framework Accelerate -o /tmp/jttytest
//   /tmp/jttytest vectors | pack | loop [snr] | wav file.wav [f0 ftol]
#include "jtty.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

static void expect_vector(const char *what, jtty_atom a, const char *bits)
{
    uint64_t want = 0;
    for (const char *p = bits; *p; p++) want = (want << 1) | (uint64_t)(*p - '0');
    uint64_t got;
    bool ok = jtty_pack_atom(&a, (want & 1) != 0, &got);
    if (!ok || got != want) {
        printf("FAIL %s: want %09llx got %09llx (%s)\n", what, (unsigned long long)want,
               (unsigned long long)got, ok ? "packed" : "rejected");
        failures++;
        return;
    }
    jtty_atom back;
    bool eom;
    char text[81];
    if (!jtty_unpack_atom(got, &back, &eom) || !jtty_render_atom(&back, text)) {
        printf("FAIL %s: did not unpack\n", what);
        failures++;
        return;
    }
    printf("ok   %s -> %09llx  \"%s\"\n", what, (unsigned long long)got, text);
}

static jtty_atom atom(int kind, int subtype, int role, int value, int value2, const char *text)
{
    jtty_atom a = { kind, subtype, role, value, value2, "" };
    if (text) snprintf(a.text, sizeof a.text, "%s", text);
    return a;
}

static void vectors(void)
{
    expect_vector("CQ K1ABC CQ", atom(JTTY_ATOM_CALL, JTTY_CALL_CQ, 0, 0, 0, "K1ABC"),
                  "0000100110111101111000110101000001");
    expect_vector("SERIAL 123 more", atom(JTTY_ATOM_EXCH_NUM, JTTY_NUM_SERIAL, 1, 123, 0, NULL),
                  "1000000000000001111011000000001000");
    expect_vector("SERIAL 123 EOM", atom(JTTY_ATOM_EXCH_NUM, JTTY_NUM_SERIAL, 1, 123, 0, NULL),
                  "1000000000000001111011000000001001");
    expect_vector("STATE CA", atom(JTTY_ATOM_EXCH_LOC, JTTY_LOC_STATE_PROVINCE, 1, 0, 0, "CA"),
                  "1000000000000110111010000000011001");
    expect_vector("ZONE_LOC3 05 NWT", atom(JTTY_ATOM_EXCH_PAIR, JTTY_PAIR_ZONE_LOC3, 0, 5, 0, "NWT"),
                  "0000001011011110010000110100101001");
    expect_vector("CLASS_SECTION 1D EMA", atom(JTTY_ATOM_EXCH_PAIR, JTTY_PAIR_CLASS_SECTION, 0, 1, 11, "D"),
                  "0010000010110001011000000000101001");
    expect_vector("NUM_TIME 156 1749", atom(JTTY_ATOM_EXCH_NUM_TIME, 0, 1, 156, 17 * 60 + 49, NULL),
                  "1000000100111001000010110100111001");
    expect_vector("CONTROL AGN?", atom(JTTY_ATOM_CONTROL, JTTY_CONTROL_AGN, 0, 0, 0, NULL),
                  "0000000000000000000000000001001001");
    expect_vector("GRID4 FN42", atom(JTTY_ATOM_GRID4, 0, 0, 0, 0, "FN42"),
                  "0001001010000110011000000001001001");
    expect_vector("TEXT5 HELLO", atom(JTTY_ATOM_TEXT5, 0, 0, 0, 0, "HELLO"),
                  "0100010011100101010101010110001101");
    // The other call actions, from the source-codec unit test.
    const char *calls[6] = {
        "0000100110111101111000110101000001", "0000100110111101111000110101010001",
        "0000100110111101111000110101100001", "0000100110111101111000110101110001",
        "0000100110111101111000110101000101", "0000100110111101111000110101010101",
    };
    for (int i = 0; i < 6; i++) {
        char what[32];
        sprintf(what, "call action %d", i);
        expect_vector(what, atom(JTTY_ATOM_CALL, i, 0, 0, 0, "K1ABC"), calls[i]);
    }
    uint64_t p;
    jtty_atom back;
    bool eom;
    if (jtty_unpack_atom(0, &back, &eom)) { printf("FAIL all-zero accepted\n"); failures++; }
    if (jtty_unpack_atom(2, &back, &eom)) { printf("FAIL reserved bit accepted\n"); failures++; }
    (void)p;
}

static void expect_pack(const char *text, int frames, int profile)
{
    uint64_t payloads[16];
    char normalized[81];
    int n = jtty_pack_text(text, profile, payloads, normalized);
    // Round trip the text through the frames.
    char rebuilt[200] = "";
    for (int i = 0; i < n; i++) {
        char t[81];
        bool sep, eom;
        if (!jtty_unpack_frame(payloads[i], t, &sep, &eom)) { strcat(rebuilt, "<bad>"); continue; }
        for (char *c = t; *c; c++) if (*c == '~') *c = ' ';
        strcat(rebuilt, t);
        if (sep && i < n - 1) strcat(rebuilt, " ");
    }
    size_t len = strlen(rebuilt);
    while (len > 0 && rebuilt[len - 1] == ' ') rebuilt[--len] = 0;
    bool match = n <= 0 || strcmp(rebuilt, normalized) == 0;
    if (n != frames || !match) {
        printf("FAIL pack \"%s\": frames %d (want %d) -> \"%s\" vs \"%s\"\n", text, n, frames, rebuilt, normalized);
        failures++;
    } else {
        printf("ok   pack %2d  \"%s\"\n", n, normalized);
    }
}

static void pack(void)
{
    expect_pack("CQ KA1ABC CQ", 1, 0);
    expect_pack("CQ K1ABC CQ", 1, 0);
    expect_pack("K1A", 1, 0);
    expect_pack("WB9XYZ", 1, 0);
    expect_pack("TU WB9XYZ CQ", 1, 0);
    expect_pack("WB9XYZ TU", 1, 0);
    expect_pack("WB9XYZ AGN?", 1, 0);
    expect_pack("TU NOW WB9XYZ", 1, 0);
    expect_pack("WB9XYZ TU CQ KA1ABC CQ", 2, 0);
    expect_pack("K1ABC TU NOW W1XYZ", 2, 0);
    expect_pack("WB9XYZ 599 123", 2, 0);
    expect_pack("599 MA", 1, 0);
    expect_pack("599 FN42", 1, 0);
    expect_pack("FN42", 1, 0);
    expect_pack("1D EMA", 1, 0);
    expect_pack("32F EMA", 1, 0);
    expect_pack("0", 1, 0);
    expect_pack("131071", 1, 0);
    expect_pack("599 131071", 1, 0);
    expect_pack("599 001", 2, 0);
    expect_pack("599 05", 2, 0);
    expect_pack("599 BRUCE", 2, 0);
    expect_pack("131072", 2, 0);
    expect_pack("000001", 2, 0);
    expect_pack("01D EMA", 2, 0);
    expect_pack("33D EMA", 2, 0);
    expect_pack("1G EMA", 2, 0);
    expect_pack("1D ZZZ", 2, 0);
    expect_pack("599 SA00", 2, 0);
    expect_pack("599 A!", 2, 0);
    expect_pack("599 XYZ", 1, 0);
    expect_pack("599 0AB", 2, 0);
    expect_pack("CQ K1ABC CQ!", 3, 0);
    expect_pack("TEST WB9XYZ", 2, 0);
    expect_pack("HI WB9XYZ", 2, 0);
    expect_pack("K1ABC HELLO", 2, 0);
    expect_pack("TEST AGN NR", 2, 0);
    expect_pack("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", 16, 0);
    expect_pack("", 0, 0);
    expect_pack("   ", 0, 0);
    expect_pack("599 A", 1, 0);
    expect_pack("599 BRUCE F", 3, 0);
    expect_pack("A599 MA", 2, 0);
    expect_pack("VP2/KF2GHI", 2, 0);
    expect_pack("VP2/KA1ABC", 2, 0);
    expect_pack("QU1RK", 1, 0);
    expect_pack("TU QU1RKP CQ", 3, 0);
    expect_pack("WB9XYZABC", 2, 0);
    expect_pack("K1A A", 1, 0);
    expect_pack("PSE AGN NR", 2, 0);
    expect_pack("AGN NR PSE", 2, 0);
    expect_pack("cq  ka1abc   cq", 1, 0);
    expect_pack("  vp2/kf2ghi  ", 2, 0);
    expect_pack("A~B", 1, 0);
    expect_pack("HELLO~", 1, 0);
    expect_pack("HELLO\tWORLD", 3, 0);
    expect_pack("THE QUICK BROWN FOX JUMPED OVER THE LAZY DOG.", 9, 0);
    expect_pack("599 001", 1, JTTY_PROFILE_RTTY_ROUNDUP);
    expect_pack("K1ABC 599 001", 2, JTTY_PROFILE_RTTY_ROUNDUP);
    expect_pack("599 05", 1, JTTY_PROFILE_RTTY_ROUNDUP);
    expect_pack("599 0123", 1, JTTY_PROFILE_RTTY_ROUNDUP);
    expect_pack("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ +-./?!\"#$%,&*()_'=[]{}<>|:;", 13, 0);
}

// MARK: - Loopback

static double gauss(void)
{
    double u1 = (rand() + 1.0) / (RAND_MAX + 2.0), u2 = (rand() + 1.0) / (RAND_MAX + 2.0);
    return sqrt(-2 * log(u1)) * cos(2 * M_PI * u2);
}

typedef struct {
    float *samples;
    long count;
} buffer;

/// Decode a buffer the way the app does: quarter-frame steps, each window
/// 1.25 frames, retro re-sweeps for anything subtracted.
static int run_receiver(buffer b, float f0, float ftol, bool wide, bool verbose, char lines[][96], int max_lines)
{
    jtty_receiver *rx = jtty_receiver_create();
    jtty_channel extra[16];
    int nextra = 0;
    if (wide) {
        for (float fc = 350; fc < 2800; fc += 300) extra[nextra++] = (jtty_channel){ fc, 150 };
    } else {
        extra[nextra++] = (jtty_channel){ 1350, 150 };
        extra[nextra++] = (jtty_channel){ 1650, 150 };
    }
    int nlines = 0;
    jtty_decode found[64];
    for (long istart = 0; istart + JTTY_CHUNK_SAMPLES <= b.count; istart += JTTY_STEP_SAMPLES) {
        jtty_receive_request req = {
            .rx_frequency = f0, .rx_tolerance = ftol,
            .extra_channels = extra, .extra_channel_count = nextra,
            .min_frequency = 200, .max_frequency = 2800,
            .window_start = istart / 12000.0,
        };
        int n = jtty_receiver_process(rx, b.samples + istart, &req, found, 64);
        jtty_decode local[64];
        memcpy(local, found, sizeof(jtty_decode) * (size_t)n);
        for (int i = 0; i < n; i++) {
            if (verbose) printf("%8.3f %7.1f %+4.0f ch%d sync%2d %s%s\n", local[i].sync_time, local[i].frequency,
                                local[i].snr, local[i].channel, local[i].sync_matches, local[i].text, local[i].eom ? " <EOM>" : "");
            if (nlines < max_lines) snprintf(lines[nlines++], 96, "%s", local[i].text);
        }
        for (int i = 0; i < n; i++) {
            for (int k = 1; k <= 3; k++) {
                long prev = istart - k * JTTY_STEP_SAMPLES;
                if (prev < 0) continue;
                jtty_known_signal known = { local[i].frequency, local[i].sync_time, local[i].payload };
                jtty_receive_request r2 = req;
                r2.window_start = prev / 12000.0;
                r2.known = &known;
                int m = jtty_receiver_process(rx, b.samples + prev, &r2, found, 64);
                for (int j = 0; j < m; j++) {
                    if (verbose) printf("%8.3f %7.1f %+4.0f ch%d sync%2d %s%s  (retro)\n", found[j].sync_time, found[j].frequency,
                                        found[j].snr, found[j].channel, found[j].sync_matches, found[j].text, found[j].eom ? " <EOM>" : "");
                    if (nlines < max_lines) snprintf(lines[nlines++], 96, "%s", found[j].text);
                }
            }
        }
    }
    jtty_receiver_destroy(rx);
    return nlines;
}

static void loop(float snr_db)
{
    const char *text = "CQ K1ABC CQ";
    uint64_t payloads[16];
    char normalized[81];
    int nframes = jtty_pack_text(text, 0, payloads, normalized);
    uint8_t tones[59 * 16];
    int nsym = jtty_message_tones(payloads, nframes, tones);
    int nwave = nsym * JTTY_NSPS;
    long total = 12000 * 3 + nwave + 12000 * 3;
    int trials = 20, good = 0;
    srand(1);
    for (int trial = 0; trial < trials; trial++) {
        float *audio = calloc((size_t)total, sizeof(float));
        float f0 = 1500 + (rand() % 100 - 50);
        float *wave = malloc(sizeof(float) * (size_t)nwave);
        jtty_render_audio(tones, nsym, f0, wave);
        // Signal amplitude for the requested SNR in 2500 Hz: noise sigma
        // such that signal power / (noise power in 2500 Hz) = snr.
        double sigma = 1.0; // noise per sample, white over 6000 Hz
        double noise_in_2500 = sigma * sigma * 2500.0 / 6000.0;
        double amp = sqrt(2 * noise_in_2500 * pow(10, snr_db / 10));
        for (long i = 0; i < total; i++) audio[i] = (float)(0.1 * sigma * gauss());
        long start = 12000 * 3 + (rand() % 6000);
        for (int i = 0; i < nwave; i++) audio[start + i] += (float)(0.1 * amp * wave[i]);
        char lines[16][96];
        int n = run_receiver((buffer){ audio, total }, 1500, 100, false, false, lines, 16);
        bool ok = n > 0 && strcmp(lines[0], normalized) == 0;
        if (ok) good++;
        printf("trial %2d f0=%6.1f start=%6.3f decodes=%d %s\n", trial, f0, start / 12000.0, n, ok ? "ok" : "MISS");
        free(audio);
        free(wave);
    }
    printf("SNR %.1f dB: %d/%d\n", snr_db, good, trials);
}

static buffer read_wav(const char *path)
{
    buffer b = { NULL, 0 };
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return b; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 44, SEEK_SET);
    long count = (size - 44) / 2;
    int16_t *raw = malloc(sizeof(int16_t) * (size_t)count);
    fread(raw, 2, (size_t)count, f);
    fclose(f);
    b.samples = malloc(sizeof(float) * (size_t)count);
    b.count = count;
    for (long i = 0; i < count; i++) b.samples[i] = raw[i] / 32768.0f;
    free(raw);
    return b;
}

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: jttytest vectors|pack|loop [snr]|wav file [f0 ftol]\n"); return 2; }
    if (strcmp(argv[1], "vectors") == 0) vectors();
    else if (strcmp(argv[1], "pack") == 0) pack();
    else if (strcmp(argv[1], "loop") == 0) loop(argc > 2 ? atof(argv[2]) : 0);
    else if (strcmp(argv[1], "probe") == 0) {
        extern void probe(buffer, double, double);
        buffer b = read_wav(argv[2]);
        probe(b, atof(argv[3]), atof(argv[4]));
    }
    else if (strcmp(argv[1], "probe") == 0) {
        extern void probe(buffer, double, double);
        buffer b = read_wav(argv[2]);
        probe(b, atof(argv[3]), atof(argv[4]));
    }
    else if (strcmp(argv[1], "wav") == 0) {
        buffer b = read_wav(argv[2]);
        float f0 = argc > 3 ? atof(argv[3]) : 1500, ftol = argc > 4 ? atof(argv[4]) : 100;
        char lines[200][96];
        int n = run_receiver(b, f0, ftol, argc > 5, true, lines, 200);
        printf("%d frames\n", n);
    }
    if (failures) { printf("%d failures\n", failures); return 1; }
    return 0;
}

// MARK: - Probe

/// Correlate every symbol of a frame at a known start time and frequency
/// straight from the 12 kHz audio, and report hard decisions and decode
/// attempts under a few hypotheses.
void probe(buffer b, double t0, double f0)
{
    int nsps = JTTY_NSPS;
    long start = lround(t0 * 12000);
    float z[59][4][2];
    for (int s = 0; s < 59; s++) {
        for (int t = 0; t < 4; t++) {
            double f = f0 + t * 31.25, sr = 0, si = 0;
            for (int k = 0; k < nsps; k++) {
                long n = start + s * nsps + k;
                if (n < 0 || n >= b.count) continue;
                double ph = -2 * M_PI * f * n / 12000.0;
                sr += b.samples[n] * cos(ph);
                si += b.samples[n] * sin(ph);
            }
            z[s][t][0] = (float)sr; z[s][t][1] = (float)si;
        }
    }
    printf("sync hard: ");
    int nsync = 0;
    for (int s = 0; s < 13; s++) {
        int best = 0;
        for (int t = 1; t < 4; t++) if (z[s][t][0]*z[s][t][0]+z[s][t][1]*z[s][t][1] > z[s][best][0]*z[s][best][0]+z[s][best][1]*z[s][best][1]) best = t;
        printf("%d", best);
        if (best == jtty_sync_tones[s]) nsync++;
    }
    printf("  (%d/13 match, want 0223003213120)\n", nsync);
    printf("data hard: ");
    uint8_t hard[46];
    for (int s = 13; s < 59; s++) {
        int best = 0;
        for (int t = 1; t < 4; t++) if (z[s][t][0]*z[s][t][0]+z[s][t][1]*z[s][t][1] > z[s][best][0]*z[s][best][0]+z[s][best][1]*z[s][best][1]) best = t;
        hard[s - 13] = (uint8_t)best;
        printf("%d", best);
    }
    printf("\n");
    printf("margins: ");
    for (int s = 13; s < 59; s++) {
        float p[4];
        for (int t = 0; t < 4; t++) p[t] = z[s][t][0]*z[s][t][0]+z[s][t][1]*z[s][t][1];
        float best = -1, second = -1;
        for (int t = 0; t < 4; t++) { if (p[t] > best) { second = best; best = p[t]; } else if (p[t] > second) second = p[t]; }
        printf("%.0f ", 10*log10(best/second));
    }
    printf("\n");
    float half[46][4];
    for (int s = 0; s < 46; s++) for (int t = 0; t < 4; t++) half[s][t] = sqrtf(z[s+13][t][0]*z[s+13][t][0]+z[s+13][t][1]*z[s+13][t][1]);
    uint64_t payload;
    float zz[46][4][2];
    memcpy(zz, z + 13, sizeof zz);
    if (jtty_decode_frame(zz, half, &payload)) {
        char text[81]; bool sep, eom;
        bool ok = jtty_unpack_frame(payload, text, &sep, &eom);
        printf("decoded as-is: %09llx %s \"%s\"\n", (unsigned long long)payload, ok ? "valid" : "INVALID", text);
    } else {
        printf("no decode as-is\n");
    }
    float zh[46][4][2], hh[46][4];
    memset(zh, 0, sizeof zh); memset(hh, 0, sizeof hh);
    for (int s = 0; s < 46; s++) { zh[s][hard[s]][0] = 1; hh[s][hard[s]] = 1; }
    if (jtty_decode_frame(zh, hh, &payload)) {
        uint8_t re[46]; jtty_encode_frame(payload, re);
        int errs = 0; for (int s = 0; s < 46; s++) if (re[s] != hard[s]) errs++;
        char text[81]; bool sep, eom;
        bool ok = jtty_unpack_frame(payload, text, &sep, &eom);
        printf("hard-decision decode: %09llx (%d symbol disagreements) %s \"%s\"\n", (unsigned long long)payload, errs, ok ? "valid":"INVALID", text);
    } else {
        printf("hard decisions do not decode\n");
    }
    for (int s = 0; s < 46; s++) for (int t = 0; t < 4; t++) { zz[s][t][0] = z[s+13][3-t][0]; zz[s][t][1] = z[s+13][3-t][1]; hh[s][t] = half[s][3-t]; }
    if (jtty_decode_frame(zz, hh, &payload)) printf("decoded with tones reversed: %09llx\n", (unsigned long long)payload);
}
