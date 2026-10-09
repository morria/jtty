#ifndef JTTY_INTERNAL_H
#define JTTY_INTERNAL_H

#include <stdint.h>

/// Continuous-phase 4-GFSK. With `im` NULL the output is a real sine
/// waveform; otherwise a unit-amplitude complex one. `re`/`im` hold
/// nsym * nsps samples.
void jtty_gfsk_synth(const uint8_t *tones, int nsym, int nsps, float bt,
                     float sample_rate, float f0, float *re, float *im);

#endif
