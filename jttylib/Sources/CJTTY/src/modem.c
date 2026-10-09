// GFSK synthesis shared by the transmitter (real audio at 12 kHz) and the
// receiver's subtraction reference (complex at 6 kHz).
#include "jtty.h"
#include "internal.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

static float gfsk_pulse(float bt, float t)
{
    const float c = (float)(M_PI * sqrt(2.0 / log(2.0)));
    return 0.5f * (erff(c * bt * (t + 0.5f)) - erff(c * bt * (t - 0.5f)));
}

void jtty_gfsk_synth(const uint8_t *tones, int nsym, int nsps, float bt,
                     float sample_rate, float f0, float *re, float *im)
{
    if (nsym <= 0) return;
    int nwave = nsym * nsps;
    // Frequency pulse spanning three symbols, and the smoothed phase
    // increment per sample with a dummy symbol either side so the first and
    // last real symbols see a settled frequency.
    float *pulse = malloc(sizeof(float) * (size_t)(3 * nsps));
    double *dphi = calloc((size_t)(nsym + 2) * (size_t)nsps, sizeof(double));
    for (int i = 0; i < 3 * nsps; i++) {
        float t = ((i + 1) - 1.5f * nsps) / (float)nsps;
        pulse[i] = gfsk_pulse(bt, t);
    }
    const double twopi = 2.0 * M_PI;
    double dphi_peak = twopi / nsps; // modulation index 1: tone spacing = baud
    for (int j = 0; j < nsym; j++) {
        int ib = j * nsps;
        double tone = tones[j];
        for (int k = 0; k < 3 * nsps; k++) dphi[ib + k] += dphi_peak * pulse[k] * tone;
    }
    // Extend the first and last tones through the dummy symbols.
    for (int k = 0; k < 2 * nsps; k++) dphi[k] += dphi_peak * tones[0] * pulse[nsps + k];
    for (int k = 0; k < 2 * nsps; k++) dphi[nsym * nsps + k] += dphi_peak * tones[nsym - 1] * pulse[k];

    double carrier = twopi * f0 / sample_rate;
    double phi = 0;
    for (int k = 0; k < nwave; k++) {
        int j = nsps + k;
        if (im) {
            re[k] = (float)cos(phi);
            im[k] = (float)sin(phi);
        } else {
            re[k] = (float)sin(phi);
        }
        phi = fmod(phi + dphi[j] + carrier, twopi);
    }

    // Raised-cosine ramps over an eighth of a symbol at each end, so the
    // transmission starts and stops without a click.
    int nramp = (int)lround(nsps / 8.0);
    for (int i = 0; i < nramp; i++) {
        float env = (float)((1.0 - cos(twopi * i / (2.0 * nramp))) / 2.0);
        re[i] *= env;
        if (im) im[i] *= env;
        int k = nwave - nramp + i;
        float tail = (float)((1.0 + cos(twopi * i / (2.0 * nramp))) / 2.0);
        re[k] *= tail;
        if (im) im[k] *= tail;
    }
    free(pulse);
    free(dphi);
}

void jtty_render_audio(const uint8_t *tones, int nsym, float f0, float *out)
{
    jtty_gfsk_synth(tones, nsym, JTTY_NSPS, 2.0f, (float)JTTY_SAMPLE_RATE, f0, out, NULL);
}
