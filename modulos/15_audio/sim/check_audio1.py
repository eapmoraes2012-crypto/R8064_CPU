# check_audio1.py - spectrum check of aud1_out.txt: left = PSG 440.4 Hz square, right = SCC 880.6 Hz square
import sys, numpy as np
d = np.loadtxt(sys.argv[1] if len(sys.argv) > 1 else 'aud1_out.txt')
fs = 14318180 / 288.0
ok = True
for ch, name, exp in ((0, 'L (PSG #1)', 1789772.5 / (16 * 254)), (1, 'R (SCC #1)', 3579545 / (32 * 127))):
    x = d[:, ch] - d[:, ch].mean()
    w = np.hanning(len(x)); sp = np.abs(np.fft.rfft(x * w)); fr = np.fft.rfftfreq(len(x), 1 / fs)
    k = np.argmax(sp[5:]) + 5
    # parabolic interpolation of the peak
    a, b, c = np.log(sp[k-1]), np.log(sp[k]), np.log(sp[k+1]); p = 0.5 * (a - c) / (a - 2*b + c)
    f0 = (k + p) * fs / len(x)
    other = d[:, 1-ch]
    print('%s: peak %.1f Hz (expected %.1f), rms %.0f, peak-to-peak %d' % (name, f0, exp, x.std(), d[:, ch].max() - d[:, ch].min()))
    if abs(f0 - exp) > 2.0 or x.std() < 1000: ok = False
print('RESULT:', 'SPECTRUM OK' if ok else 'SPECTRUM ERROR')
