// The JTTY receiver: one window of audio in, decoded frames out.
//
// Audio is turned into a complex analytic signal at 6 kHz. The 13-symbol
// sync pattern is correlated against the first quarter-frame of the window
// at every 2 ms, which gives a surface over (start time, frequency). Peaks
// are picked from that surface band by band, refined, checked against the
// sync tones, and the 46 data symbols behind each surviving peak are
// correlated and handed to the FEC. A decoded frame is re-synthesised and
// subtracted, and the surface rebuilt, so a weaker signal underneath can be
// found on a second pass.
#include "jtty.h"
#include "internal.h"

#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FS6 6000.0f
#define NSS (JTTY_NSPS / 2)                 // 192 samples per symbol at 6 kHz
#define NCHUNK6 (JTTY_CHUNK_SAMPLES / 2)    // 14160
#define NANA 32768                          // FFT size over the 12 kHz chunk
#define NANA_LOG2 15
#define NANA6 (NANA / 2)
#define NFFT 8192                           // sync-search FFT
#define NFFT_LOG2 13
#define NH2 (NFFT / 2)
#define NFRAME6 (JTTY_FRAME_SYMBOLS * NSS)  // 11328
#define NTSTEP (NFRAME6 / 4)                // 2832
#define TGRID 12                            // sync search step, samples at 6 kHz
#define NCOL (NTSTEP / TGRID + 1)           // 237 start-time columns
#define NSYNC (JTTY_SYNC_SYMBOLS * NSS)     // 2496
#define MAXCAND 100
#define MAX_CH0_OK 16
#define NFILT (2 * NSS)
// Data-symbol SNR below which a CRC-clean decode is treated as a false
// accept. Set from measurement: see tools/jttytest.c "noise" and "loop".
#ifndef JTTY_MIN_DATA_SNR
#define JTTY_MIN_DATA_SNR 3.5f
#endif

static const float DF2 = FS6 / NFFT;        // 0.732 Hz per bin
static const float DT6 = 1.0f / FS6;

typedef struct {
    float f1, xdt, snr;
    uint64_t payload;
    bool decoded;
    float tsync;
} candidate;

struct jtty_receiver {
    FFTSetup fft;
    float *ana_re, *ana_im;   // NANA
    float *c0_re, *c0_im;     // NANA (analytic chunk at 6 kHz, valid 0..NCHUNK6)
    float *c1_re, *c1_im;     // NCHUNK6 (c0 shifted to put a candidate at DC)
    float *fft_re, *fft_im;   // NANA scratch
    float *s0;                // NCOL x (NH2 + 1)
    uint8_t *mask0;           // NCOL x (NH2 + 1)
    float csync_re[NSYNC], csync_im[NSYNC];
    float ctone_re[4][NSS], ctone_im[4][NSS];
    float *cw_re, *cw_im;     // NANA: subtraction low-pass kernel spectrum
    float *cref_re, *cref_im; // NFRAME6

    // Per-call state
    double window_start;
    int first_bin, last_bin;
    int ncol_searched;
    bool s0_valid;
    bool any_subtracted;
    candidate cand[MAXCAND];
    int ncand;
    float ok_f1[MAX_CH0_OK], ok_tsync[MAX_CH0_OK];
    int ok_ja[MAX_CH0_OK], ok_jb[MAX_CH0_OK];
    int n_ok;
    jtty_decode *out;
    int max_out, nout;
    jtty_receiver_stats stats;
};

jtty_receiver_stats jtty_receiver_last_stats(const jtty_receiver *r)
{
    return r->stats;
}

static float db(float x) { return x > 1.259e-10f ? 10.0f * log10f(x) : -99.0f; }

jtty_receiver *jtty_receiver_create(void)
{
    jtty_receiver *r = calloc(1, sizeof *r);
    r->fft = vDSP_create_fftsetup(NANA_LOG2, kFFTRadix2);
    r->ana_re = calloc(NANA, sizeof(float));
    r->ana_im = calloc(NANA, sizeof(float));
    r->c0_re = calloc(NANA, sizeof(float));
    r->c0_im = calloc(NANA, sizeof(float));
    r->c1_re = calloc(NCHUNK6, sizeof(float));
    r->c1_im = calloc(NCHUNK6, sizeof(float));
    r->fft_re = calloc(NANA, sizeof(float));
    r->fft_im = calloc(NANA, sizeof(float));
    r->s0 = calloc((size_t)NCOL * (NH2 + 1), sizeof(float));
    r->mask0 = calloc((size_t)NCOL * (NH2 + 1), 1);
    r->cw_re = calloc(NANA, sizeof(float));
    r->cw_im = calloc(NANA, sizeof(float));
    r->cref_re = calloc(NFRAME6, sizeof(float));
    r->cref_im = calloc(NFRAME6, sizeof(float));

    // Sync reference: the 13 tones as pure phase-continuous sinusoids.
    double phi = 0, twopi = 2 * M_PI;
    for (int i = 0, k = 0; i < JTTY_SYNC_SYMBOLS; i++) {
        double dphi = twopi * jtty_sync_tones[i] / NSS;
        for (int j = 0; j < NSS; j++, k++) {
            r->csync_re[k] = (float)cos(phi);
            r->csync_im[k] = (float)sin(phi);
            phi += dphi;
        }
    }
    for (int t = 0; t < 4; t++) {
        double p = 0, dphi = twopi * t / NSS;
        for (int j = 0; j < NSS; j++) {
            r->ctone_re[t][j] = (float)cos(p);
            r->ctone_im[t][j] = (float)sin(p);
            p += dphi;
        }
    }

    // Subtraction smoothing kernel: a cos^2 window two symbols long, centred
    // on sample 0 circularly, as a spectrum scaled for the unnormalised
    // transform pair.
    double sum = 0;
    for (int j = -NFILT / 2; j <= NFILT / 2; j++) sum += pow(cos(M_PI * j / NFILT), 2);
    for (int j = -NFILT / 2; j <= NFILT / 2; j++) {
        int k = j < 0 ? j + NANA : j;
        r->cw_re[k] = (float)(pow(cos(M_PI * j / NFILT), 2) / sum / NANA);
    }
    DSPSplitComplex cw = { r->cw_re, r->cw_im };
    vDSP_fft_zip(r->fft, &cw, 1, NANA_LOG2, kFFTDirection_Forward);
    return r;
}

void jtty_receiver_destroy(jtty_receiver *r)
{
    if (!r) return;
    vDSP_destroy_fftsetup(r->fft);
    free(r->ana_re); free(r->ana_im); free(r->c0_re); free(r->c0_im);
    free(r->c1_re); free(r->c1_im); free(r->fft_re); free(r->fft_im);
    free(r->s0); free(r->mask0); free(r->cw_re); free(r->cw_im);
    free(r->cref_re); free(r->cref_im);
    free(r);
}

// MARK: - Analytic signal

/// Real 12 kHz samples to a complex analytic signal at 6 kHz: forward FFT,
/// drop the negative frequencies, inverse FFT at half the size.
static void analytic(jtty_receiver *r, const float *samples)
{
    float fac = 2.0f / NANA;
    memset(r->ana_re, 0, NANA * sizeof(float));
    memset(r->ana_im, 0, NANA * sizeof(float));
    vDSP_vsmul(samples, 1, &fac, r->ana_re, 1, JTTY_CHUNK_SAMPLES);
    DSPSplitComplex a = { r->ana_re, r->ana_im };
    vDSP_fft_zip(r->fft, &a, 1, NANA_LOG2, kFFTDirection_Forward);
    memset(r->ana_re + NANA6 / 2 + 1, 0, (NANA6 / 2 - 1) * sizeof(float));
    memset(r->ana_im + NANA6 / 2 + 1, 0, (NANA6 / 2 - 1) * sizeof(float));
    r->ana_re[0] *= 0.5f;
    r->ana_im[0] *= 0.5f;
    vDSP_fft_zip(r->fft, &a, 1, NANA_LOG2 - 1, kFFTDirection_Inverse);
    memset(r->c0_re, 0, NANA * sizeof(float));
    memset(r->c0_im, 0, NANA * sizeof(float));
    memcpy(r->c0_re, r->ana_re, NCHUNK6 * sizeof(float));
    memcpy(r->c0_im, r->ana_im, NCHUNK6 * sizeof(float));
}

/// c1 = c0 shifted down by `f` Hz, over the valid part of the chunk.
static void shift_to_dc(jtty_receiver *r, float f, int count)
{
    double dphi = -2.0 * M_PI * f / FS6;
    float wr = 1, wi = 0;
    float sr = (float)cos(dphi), si = (float)sin(dphi);
    for (int i = 0; i < count; i++) {
        float nr = wr * sr - wi * si;
        float ni = wr * si + wi * sr;
        wr = nr; wi = ni;
        r->c1_re[i] = wr * r->c0_re[i] - wi * r->c0_im[i];
        r->c1_im[i] = wr * r->c0_im[i] + wi * r->c0_re[i];
    }
}

// MARK: - Sync search surface

static void build_s0(jtty_receiver *r)
{
    int first = r->first_bin, last = r->last_bin;
    DSPSplitComplex f = { r->fft_re, r->fft_im };
    int col = 0;
    for (int i0 = 0; i0 <= NTSTEP; i0 += TGRID, col++) {
        // conj(sync) * signal, zero padded.
        for (int k = 0; k < NSYNC; k++) {
            float ar = r->csync_re[k], ai = -r->csync_im[k];
            float br = r->c0_re[i0 + k], bi = r->c0_im[i0 + k];
            r->fft_re[k] = ar * br - ai * bi;
            r->fft_im[k] = ar * bi + ai * br;
        }
        memset(r->fft_re + NSYNC, 0, (NFFT - NSYNC) * sizeof(float));
        memset(r->fft_im + NSYNC, 0, (NFFT - NSYNC) * sizeof(float));
        vDSP_fft_zip(r->fft, &f, 1, NFFT_LOG2, kFFTDirection_Forward);
        float *row = r->s0 + (size_t)col * (NH2 + 1);
        // Five-bin smoothing, 1-2-3-2-1, within a two-bin halo of the range.
        float p[5];
        for (int k = 0; k < 4; k++) {
            int j = first - 2 + k;
            p[k] = r->fft_re[j] * r->fft_re[j] + r->fft_im[j] * r->fft_im[j];
        }
        for (int j = first; j <= last; j++) {
            int jj = j + 2;
            p[4] = r->fft_re[jj] * r->fft_re[jj] + r->fft_im[jj] * r->fft_im[jj];
            row[j] = p[0] + 2 * p[1] + 3 * p[2] + 2 * p[3] + p[4];
            p[0] = p[1]; p[1] = p[2]; p[2] = p[3]; p[3] = p[4];
        }
    }
    r->ncol_searched = col;
    r->s0_valid = true;
}

typedef struct {
    float fc, fwid;
    int ja, jb;
    bool usable;
    bool primary;
} channel;

static void channel_bins(channel *c, float min_f, float max_f, bool constrain)
{
    float fc = c->fc;
    c->usable = false;
    if (constrain) {
        if (min_f > max_f) return;
        if (fc < min_f) fc = min_f;
        if (fc > max_f) fc = max_f;
    }
    int ja = (int)((fc - c->fwid) / DF2);
    int jb = (int)((fc + c->fwid) / DF2);
    if (ja < 3) ja = 3;
    if (jb > NH2 - 2) jb = NH2 - 2;
    if (constrain) {
        int lo = (int)ceilf(min_f / DF2), hi = (int)floorf(max_f / DF2);
        if (ja < lo) ja = lo;
        if (jb > hi) jb = hi;
    }
    c->ja = ja;
    c->jb = jb;
    c->usable = ja <= jb;
}

// MARK: - Refinement

/// Sharpen a coarse (time, frequency) estimate: search +-4 ms in 4-sample
/// hops and +-2.5 Hz in half-hertz steps for the strongest sync
/// correlation, then fit the phase ramp across the 13 symbols to get the
/// residual frequency error.
static void peakup(jtty_receiver *r, float xdt0, float f0, float *xdt, float *f1, float *snr)
{
    const int hop = 4;
    int ia = (int)lroundf((xdt0 - 0.004f) / DT6);
    int ib = (int)lroundf((xdt0 + 0.004f) / DT6);
    if (ia < 0) ia = 0;
    if (ib > NCHUNK6 - NSYNC) ib = NCHUNK6 - NSYNC;
    float pmax = 0, fpk = f0, xdtpk = xdt0;
    float zbest_re[13] = { 0 }, zbest_im[13] = { 0 };
    for (int idf = -5; idf <= 5; idf++) {
        float f = f0 - 0.5f * idf;
        if (ia > ib) break;
        shift_to_dc(r, f, ib + NSYNC);
        for (int i0 = ia; i0 <= ib; i0 += hop) {
            float p = 0, zr[13], zi[13];
            for (int i = 0; i < 13; i++) {
                float sr = 0, si = 0;
                const float *cr = r->c1_re + i0 + i * NSS, *ci = r->c1_im + i0 + i * NSS;
                const float *yr = r->csync_re + i * NSS, *yi = r->csync_im + i * NSS;
                for (int k = 0; k < NSS; k++) {
                    // conj(sync) * signal
                    sr += yr[k] * cr[k] + yi[k] * ci[k];
                    si += yr[k] * ci[k] - yi[k] * cr[k];
                }
                zr[i] = sr; zi[i] = si;
                p += sr * sr + si * si;
            }
            if (p > pmax) {
                pmax = p;
                fpk = f;
                xdtpk = i0 * DT6;
                memcpy(zbest_re, zr, sizeof zr);
                memcpy(zbest_im, zi, sizeof zi);
            }
        }
    }
    if (pmax > 0) {
        float tsym = NSS / FS6;
        float uw[13];
        uw[0] = atan2f(zbest_im[0], zbest_re[0]);
        float prev = uw[0];
        for (int i = 1; i < 13; i++) {
            float ph = atan2f(zbest_im[i], zbest_re[i]);
            float d = ph - prev;
            while (d > M_PI) d -= 2 * M_PI;
            while (d < -M_PI) d += 2 * M_PI;
            uw[i] = uw[i - 1] + d;
            prev = ph;
        }
        float xm = 6, ym = 0;
        for (int i = 0; i < 13; i++) ym += uw[i];
        ym /= 13;
        float sxy = 0, sxx = 0;
        for (int i = 0; i < 13; i++) {
            sxy += (i - xm) * (uw[i] - ym);
            sxx += (i - xm) * (i - xm);
        }
        float slope = sxy / sxx, intercept = ym - slope * xm, resid = 0;
        for (int i = 0; i < 13; i++) {
            float e = uw[i] - (slope * i + intercept);
            resid += e * e;
        }
        resid = sqrtf(resid / 13);
        float dfhz = slope / (2 * (float)M_PI * tsym);
        if (resid < 1.0f && fabsf(dfhz) <= 0.5f) {
            float tr = 0, ti = 0;
            for (int i = 0; i < 13; i++) {
                float c = cosf(-slope * i), s = sinf(-slope * i);
                tr += zbest_re[i] * c - zbest_im[i] * s;
                ti += zbest_re[i] * s + zbest_im[i] * c;
            }
            fpk += dfhz;
            pmax = tr * tr + ti * ti;
        }
    }
    *f1 = fpk;
    *xdt = xdtpk;
    *snr = pmax;
}

// MARK: - Subtraction

static void subtract(jtty_receiver *r, uint64_t payload, float f1, float xdt)
{
    uint8_t tones[JTTY_FRAME_SYMBOLS];
    jtty_frame_tones(payload, tones);
    jtty_gfsk_synth(tones, JTTY_FRAME_SYMBOLS, NSS, 2.0f, FS6, f1, r->cref_re, r->cref_im);
    int nstart = (int)lroundf(xdt * FS6);
    memset(r->fft_re, 0, NANA * sizeof(float));
    memset(r->fft_im, 0, NANA * sizeof(float));
    for (int i = 0; i < NFRAME6; i++) {
        int j = nstart + i;
        if (j < 0 || j >= NCHUNK6) continue;
        // signal * conj(reference): the complex gain, before smoothing.
        r->fft_re[i] = r->c0_re[j] * r->cref_re[i] + r->c0_im[j] * r->cref_im[i];
        r->fft_im[i] = r->c0_im[j] * r->cref_re[i] - r->c0_re[j] * r->cref_im[i];
    }
    DSPSplitComplex f = { r->fft_re, r->fft_im };
    DSPSplitComplex cw = { r->cw_re, r->cw_im };
    vDSP_fft_zip(r->fft, &f, 1, NANA_LOG2, kFFTDirection_Forward);
    vDSP_zvmul(&f, 1, &cw, 1, &f, 1, NANA, 1);
    vDSP_fft_zip(r->fft, &f, 1, NANA_LOG2, kFFTDirection_Inverse);
    for (int i = 0; i < NFRAME6; i++) {
        int j = nstart + i;
        if (j < 0 || j >= NCHUNK6) continue;
        float gr = r->fft_re[i], gi = r->fft_im[i];
        r->c0_re[j] -= gr * r->cref_re[i] - gi * r->cref_im[i];
        r->c0_im[j] -= gr * r->cref_im[i] + gi * r->cref_re[i];
    }
}

// MARK: - Decoding one candidate

static bool same_frame(float fa, float ta, float fb, float tb)
{
    return fabsf(fa - fb) < 3.0f && fabsf(ta - tb) < 0.05f;
}

/// Correlate the 46 data symbols of the candidate at c1 (already shifted to
/// its frequency), run the FEC, validate the grammar, and if it is a new
/// decode subtract it and report it. `pt`/`pa` carry the sync-symbol power
/// sums in for the SNR estimate.
static bool decode_candidate(jtty_receiver *r, const jtty_receive_request *req,
                             int ichan, int nsync, float pt, float pa)
{
    candidate *c = &r->cand[r->ncand - 1];
    float z[JTTY_DATA_SYMBOLS][4][2];
    float half[JTTY_DATA_SYMBOLS][4];
    memset(z, 0, sizeof z);
    memset(half, 0, sizeof half);
    int payload_start = (int)lroundf(c->xdt / DT6) + JTTY_SYNC_SYMBOLS * NSS;
    if (payload_start < 0) return false;
    int available = (NCHUNK6 - payload_start) / NSS;
    if (available > JTTY_DATA_SYMBOLS) available = JTTY_DATA_SYMBOLS;
    for (int s = 0; s < available; s++) {
        int first = payload_start + s * NSS;
        for (int t = 0; t < 4; t++) {
            float fr = 0, fi = 0, e = 0;
            for (int segment = 0; segment < 2; segment++) {
                float hr = 0, hi = 0;
                for (int k = segment * NSS / 2; k < (segment + 1) * NSS / 2; k++) {
                    float sr = r->c1_re[first + k], si = r->c1_im[first + k];
                    float yr = r->ctone_re[t][k], yi = r->ctone_im[t][k];
                    hr += yr * sr + yi * si;
                    hi += yr * si - yi * sr;
                }
                fr += hr; fi += hi;
                e += hr * hr + hi * hi;
            }
            z[s][t][0] = fr;
            z[s][t][1] = fi;
            half[s][t] = sqrtf(e);
        }
    }
    uint64_t payload;
    if (!jtty_decode_frame(z, half, &payload)) return false;
    char text[JTTY_MAX_TEXT + 1];
    bool trailing_sep, eom;
    if (!jtty_unpack_frame(payload, text, &trailing_sep, &eom)) return false;

    // SNR over the whole frame: power in the expected tone against the
    // other three. The data symbols are also judged on their own: the sync
    // already passed a gate, so only they say whether the decoded word is
    // what was sent. A real frame at the decoding threshold puts several dB
    // more energy in its tones than in the others; a false decode is random
    // against the data and shows about 0 dB.
    uint8_t expected[JTTY_DATA_SYMBOLS];
    jtty_encode_frame(payload, expected);
    float pt_data = 0, pa_data = 0;
    for (int s = 0; s < JTTY_DATA_SYMBOLS; s++) {
        for (int t = 0; t < 4; t++) {
            float p = z[s][t][0] * z[s][t][0] + z[s][t][1] * z[s][t][1];
            pa_data += p;
            if (t == expected[s]) pt_data += p;
        }
    }
    float pn_data = (pa_data - pt_data) / 3;
    float data_snr = pn_data > 0 ? db(pt_data / pn_data) : 0;
    if (getenv("JTTY_DEBUG")) fprintf(stderr, "  decode data-snr %.1f dB sync-snr %.1f dB text %s\n", data_snr, c->snr, text);
    if (data_snr < JTTY_MIN_DATA_SNR) return false;
    pt += pt_data;
    pa += pa_data;
    float pn = (pa - pt) / 3;
    float snrdb = pn > 0 ? db(pt / pn) : c->snr;
    c->snr = snrdb;
    c->payload = payload;
    c->decoded = true;
    c->tsync = (float)(req->window_start + c->xdt);

    // The same frame found twice in this call is sync-estimation noise.
    for (int i = 0; i < r->ncand - 1; i++) {
        if (r->cand[i].decoded && r->cand[i].payload == payload &&
            fabsf(r->cand[i].tsync - c->tsync) < 0.032f) return true;
    }
    if (ichan != 0) {
        for (int i = 0; i < r->n_ok; i++) {
            if (same_frame(c->f1, c->tsync, r->ok_f1[i], r->ok_tsync[i])) return true;
        }
    }

    subtract(r, payload, c->f1, c->xdt);
    r->any_subtracted = true;
    r->s0_valid = false;

    if (r->nout < r->max_out) {
        jtty_decode *d = &r->out[r->nout++];
        memset(d, 0, sizeof *d);
        d->payload = payload;
        d->frequency = c->f1;
        d->sync_time = c->tsync;
        d->snr = snrdb - 20.0f;
        d->channel = ichan;
        d->sync_matches = nsync;
        d->eom = eom;
        d->trailing_sep = trailing_sep;
        strcpy(d->text, text);
    }
    return true;
}

static void record_ok(jtty_receiver *r, int ichan)
{
    if (ichan != 0 || r->n_ok >= MAX_CH0_OK) return;
    candidate *c = &r->cand[r->ncand - 1];
    int bin = (int)lroundf(c->f1 / DF2);
    int nfz = (int)lroundf(10.0f / DF2);
    r->ok_ja[r->n_ok] = bin - nfz;
    r->ok_jb[r->n_ok] = bin + nfz;
    r->ok_f1[r->n_ok] = c->f1;
    r->ok_tsync[r->n_ok] = c->tsync;
    r->n_ok++;
}

/// Tone powers over the 13 sync symbols of the current candidate.
static void sync_gate(jtty_receiver *r, float xdt, int *nsync, float *snr, float *pt, float *pa)
{
    *pt = 0; *pa = 0; *nsync = 0;
    int start = (int)lroundf(xdt / DT6);
    for (int j = 0; j < JTTY_SYNC_SYMBOLS; j++) {
        int i0 = start + j * NSS;
        if (i0 < 0 || i0 + NSS > NCHUNK6) break;
        float pow4[4];
        int best = 0;
        for (int t = 0; t < 4; t++) {
            float sr = 0, si = 0;
            for (int k = 0; k < NSS; k++) {
                float xr = r->c1_re[i0 + k], xi = r->c1_im[i0 + k];
                sr += r->ctone_re[t][k] * xr + r->ctone_im[t][k] * xi;
                si += r->ctone_re[t][k] * xi - r->ctone_im[t][k] * xr;
            }
            pow4[t] = sr * sr + si * si;
            if (pow4[t] > pow4[best]) best = t;
        }
        if (best == jtty_sync_tones[j]) (*nsync)++;
        *pt += pow4[jtty_sync_tones[j]];
        *pa += pow4[0] + pow4[1] + pow4[2] + pow4[3];
    }
    float pn = (*pa - *pt) / 3;
    *snr = pn > 0 ? db(*pt / pn) : -99.9f;
}

// MARK: - Channel sweep

static void process_channel(jtty_receiver *r, const jtty_receive_request *req,
                            channel *ch, int ichan)
{
    if (!ch->usable) return;
    int nfz = (int)lroundf(10.0f / DF2);
    int ntz = (int)lroundf(0.016f * FS6 / TGRID);
    int nc = 2;
    if (ichan == 0) {
        nc = (int)lroundf(ch->fwid / (nfz * DF2));
        if (nc < 2) nc = 2;
        if (nc > 8) nc = 8;
    }
    int ncols = r->ncol_searched;
    size_t stride = NH2 + 1;

    if (ichan != 0 && r->n_ok > 0) {
        // Keep the secondary channels off what the primary already found,
        // but only its exact neighbourhoods, not its whole band.
        for (int i = 0; i < r->n_ok; i++) {
            int lo = r->ok_ja[i] > ch->ja ? r->ok_ja[i] : ch->ja;
            int hi = r->ok_jb[i] < ch->jb ? r->ok_jb[i] : ch->jb;
            if (lo > hi) continue;
            for (int col = 0; col < ncols; col++) {
                memset(r->s0 + col * stride + lo, 0, (size_t)(hi - lo + 1) * sizeof(float));
            }
        }
    }
    if (ichan == 0) {
        for (int col = 0; col < ncols; col++) {
            memset(r->mask0 + col * stride + ch->ja, 1, (size_t)(ch->jb - ch->ja + 1));
        }
    }

    bool channel_decoded = false;
    for (int ic = 0; ic < nc; ic++) {
        // Strongest remaining point on the surface within the band.
        float best = -1;
        int bbin = ch->ja, bcol = 0;
        for (int col = 0; col < ncols; col++) {
            const float *row = r->s0 + col * stride;
            const uint8_t *mask = r->mask0 + col * stride;
            for (int j = ch->ja; j <= ch->jb; j++) {
                if (ichan == 0 && !mask[j]) continue;
                if (row[j] > best) { best = row[j]; bbin = j; bcol = col; }
            }
        }
        int lo = bbin - nfz < ch->ja ? ch->ja : bbin - nfz;
        int hi = bbin + nfz > ch->jb ? ch->jb : bbin + nfz;
        int c0 = bcol - ntz < 0 ? 0 : bcol - ntz;
        int c1 = bcol + ntz >= ncols ? ncols - 1 : bcol + ntz;
        for (int col = c0; col <= c1; col++) {
            if (ichan == 0) memset(r->mask0 + col * stride + lo, 0, (size_t)(hi - lo + 1));
            else memset(r->s0 + col * stride + lo, 0, (size_t)(hi - lo + 1) * sizeof(float));
        }
        if (best <= 0) break;
        float fbest = bbin * DF2;
        float xdtbest = bcol * TGRID * DT6;
        float xdt1, f11, snr0;
        peakup(r, xdtbest, fbest, &xdt1, &f11, &snr0);

        if (r->ncand >= MAXCAND) break;
        candidate *c = &r->cand[r->ncand++];
        memset(c, 0, sizeof *c);
        c->xdt = xdt1;
        c->f1 = f11;
        shift_to_dc(r, c->f1, NCHUNK6);
        int nsync;
        float snr, pt, pa;
        sync_gate(r, c->xdt, &nsync, &snr, &pt, &pa);
        c->snr = snr;
        r->stats.candidates++;
        if (getenv("JTTY_DEBUG")) fprintf(stderr, "  cand ch%d t=%.3f f=%.1f coarse(%.3f,%.1f) nsync=%d snr=%.1f\n",
                                          ichan, req->window_start + c->xdt, c->f1, req->window_start + xdtbest, fbest, nsync, snr);
        if (ichan == 0 && (nsync <= 6 || snr < 4.6f)) continue;
        if (ichan != 0 && (nsync <= 8 || snr < 5.0f)) continue;
        r->stats.sync_hits++;
        if (decode_candidate(r, req, ichan, nsync, pt, pa)) {
            record_ok(r, ichan);
            channel_decoded = true;
        }
    }

    if (!channel_decoded) {
        // Nothing found: if a message in progress is due exactly one frame
        // after its last one, try the FEC straight at that point.
        for (int i = 0; i < req->continuation_count; i++) {
            const jtty_continuation *h = &req->continuations[i];
            if (h->frequency < ch->fc - ch->fwid || h->frequency > ch->fc + ch->fwid) continue;
            float period = NFRAME6 / FS6;
            if (fabs((req->window_start - h->sync_time) - period) > 0.1) continue;
            float xdt_retry = (float)(h->sync_time + period - req->window_start);
            if (xdt_retry < 0) continue;
            if (r->ncand >= MAXCAND) break;
            candidate *c = &r->cand[r->ncand++];
            memset(c, 0, sizeof *c);
            c->xdt = xdt_retry;
            c->f1 = h->frequency;
            shift_to_dc(r, c->f1, NCHUNK6);
            int nsync;
            float snr, pt, pa;
            sync_gate(r, c->xdt, &nsync, &snr, &pt, &pa);
            c->snr = snr;
            if (decode_candidate(r, req, ichan, -1, pt, pa)) record_ok(r, ichan);
            break;
        }
    }
}

int jtty_receiver_process(jtty_receiver *r, const float *samples,
                          const jtty_receive_request *req,
                          jtty_decode *out, int max_out)
{
    r->out = out;
    r->max_out = max_out;
    r->nout = 0;
    r->ncand = 0;
    r->n_ok = 0;
    memset(&r->stats, 0, sizeof r->stats);
    r->window_start = req->window_start;

    float energy = 0;
    vDSP_svesq(samples, 1, &energy, JTTY_CHUNK_SAMPLES);
    if (energy <= 0) return 0;

    analytic(r, samples);

    if (req->known) {
        // A later window found this signal; take it out before searching so
        // whatever it was sitting on has a chance.
        float xdt = (float)(req->known->sync_time - req->window_start);
        subtract(r, req->known->payload, req->known->frequency, xdt);
    }

    int nchan = 1 + req->extra_channel_count;
    if (nchan > 32) nchan = 32;
    channel channels[32];
    channels[0].fc = req->rx_frequency;
    channels[0].fwid = req->rx_tolerance;
    channels[0].primary = true;
    channel_bins(&channels[0], req->min_frequency, req->max_frequency, false);
    for (int i = 1; i < nchan; i++) {
        channels[i].fc = req->extra_channels[i - 1].centre;
        channels[i].fwid = req->extra_channels[i - 1].half_width;
        channels[i].primary = false;
        channel_bins(&channels[i], req->min_frequency, req->max_frequency, true);
    }
    r->first_bin = NH2 - 2;
    r->last_bin = 3;
    for (int i = 0; i < nchan; i++) {
        if (!channels[i].usable) continue;
        if (channels[i].ja < r->first_bin) r->first_bin = channels[i].ja;
        if (channels[i].jb > r->last_bin) r->last_bin = channels[i].jb;
    }
    if (r->first_bin > r->last_bin) return 0;

    r->s0_valid = false;
    r->any_subtracted = false;
    memset(r->mask0, 0, (size_t)NCOL * (NH2 + 1));

    // The receive frequency gets first claim on everything, with a second
    // pass over the residual if it took anything out.
    for (int pass = 0; pass < 2; pass++) {
        if (pass == 1 && !r->any_subtracted) break;
        if (!r->s0_valid) build_s0(r);
        process_channel(r, req, &channels[0], 0);
    }
    r->any_subtracted = false;
    for (int pass = 0; pass < 2; pass++) {
        if (pass == 1 && !r->any_subtracted) break;
        if (!r->s0_valid) build_s0(r);
        for (int i = 1; i < nchan; i++) process_channel(r, req, &channels[i], i);
        r->s0_valid = false;
    }
    r->stats.decodes = r->nout;
    return r->nout;
}
