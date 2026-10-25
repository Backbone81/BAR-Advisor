"""Generate a voice line for the Advisor widget with Piper and match its loudness to BAR's own voice lines.

Usage, in a Python environment with piper-tts and numpy and a downloaded Piper voice (<voice>.onnx with
<voice>.onnx.json next to it):

    python -I make_voice_line.py --voice <voice>.onnx <name>.txt

Reads the text from <name>.txt and writes <name>.wav next to it. The text may contain raw phonemes in [[...]], which
override espeak's pronunciation (see tech_one_constructor_idle.txt). Piper's output varies between runs, so listen to
a line before keeping it.
"""

import argparse
import io
import wave
from pathlib import Path

import numpy as np
from piper import PiperVoice

# Loudness of the finished line as RMS relative to full scale. 8300 of 32768 is the median of BAR's own voice lines
# (the "cephis" announcer); the widget plays its lines at volume 0.7 like BAR's notifications, so the same RMS here
# means the same loudness in game.
TARGET_RMS = 8300 / 32768

# Peaks above this level (relative to full scale) are compressed smoothly towards full scale instead of clipping.
LIMITER_KNEE = 0.7

# Piper writes mono 16-bit PCM. Samples are processed as floats in [-1, 1).
SAMPLE_WIDTH_BYTES = 2
PCM_FULL_SCALE = 32768

# The gain search stops once the RMS is within 0.1 % of the target, or after GAIN_MAX_STEPS steps.
GAIN_TOLERANCE = 1e-3
GAIN_MAX_STEPS = 20


def rms(samples: np.ndarray) -> float:
    """Return the root mean square of the samples, a measure of their average loudness."""
    return float(np.sqrt(np.mean(samples**2)))


def soft_limit(samples: np.ndarray) -> np.ndarray:
    """Compress magnitudes above LIMITER_KNEE along a tanh curve that approaches full scale but never reaches it.

    Samples below the knee pass unchanged, so the line keeps its character while loud peaks no longer clip.
    """
    magnitude = np.abs(samples)
    over = magnitude > LIMITER_KNEE
    headroom = 1 - LIMITER_KNEE
    limited = samples.copy()
    limited[over] = np.sign(samples[over]) * (
        LIMITER_KNEE + headroom * np.tanh((magnitude[over] - LIMITER_KNEE) / headroom)
    )
    return limited


def match_loudness(samples: np.ndarray) -> tuple[np.ndarray, float]:
    """Amplify and limit the samples until their RMS reaches TARGET_RMS.

    Limiting takes energy out of the peaks, so a gain computed from the unlimited signal falls short of the target.
    The gain is therefore raised step by step by the remaining shortfall of the limited signal, which converges
    within a few steps.

    Returns the processed samples and the gain that was applied before limiting.
    """
    level = rms(samples)
    if level == 0:
        raise ValueError("Piper produced silence")
    gain = TARGET_RMS / level
    for _ in range(GAIN_MAX_STEPS):
        shortfall = TARGET_RMS / rms(soft_limit(samples * gain))
        gain *= shortfall
        if abs(shortfall - 1) < GAIN_TOLERANCE:
            break
    return soft_limit(samples * gain), gain


def synthesize(voice: PiperVoice, text: str) -> tuple[np.ndarray, int]:
    """Speak the text with Piper and return the samples as floats in [-1, 1) and the sample rate."""
    # Piper only writes to a wave file object, so let it write one in memory and read the samples back from it.
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        voice.synthesize_wav(text, wav)
    buffer.seek(0)
    with wave.open(buffer, "rb") as wav:
        if wav.getnchannels() != 1 or wav.getsampwidth() != SAMPLE_WIDTH_BYTES:
            raise ValueError("expected mono 16-bit audio from Piper")
        sample_rate = wav.getframerate()
        pcm = np.frombuffer(wav.readframes(wav.getnframes()), dtype=np.int16)
    return pcm.astype(np.float64) / PCM_FULL_SCALE, sample_rate


def write_wav(path: Path, samples: np.ndarray, sample_rate: int) -> None:
    """Write float samples in [-1, 1] as a mono 16-bit PCM WAV file."""
    pcm = (np.clip(samples, -1, 1) * (PCM_FULL_SCALE - 1)).astype(np.int16)
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(SAMPLE_WIDTH_BYTES)
        wav.setframerate(sample_rate)
        wav.writeframes(pcm.tobytes())


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("text_file", type=Path, help="<name>.txt; the line is written to <name>.wav next to it")
    parser.add_argument("--voice", type=Path, required=True, help="Piper voice model, e.g. en_US-amy-medium.onnx")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    text = args.text_file.read_text(encoding="utf-8").strip()
    out_path = args.text_file.with_suffix(".wav")

    voice = PiperVoice.load(args.voice)
    # The phonemes show how espeak read the text, e.g. whether "Tech-one" became a single word.
    print("phonemes:", ["".join(sentence) for sentence in voice.phonemize(text)])

    samples, sample_rate = synthesize(voice, text)
    line, gain = match_loudness(samples)
    write_wav(out_path, line, sample_rate)

    duration = len(line) / sample_rate
    gain_db = 20 * np.log10(gain)
    print(f"{out_path}: {duration:.2f} s, gain {gain_db:+.1f} dB, rms {rms(line) * PCM_FULL_SCALE:.0f}")


if __name__ == "__main__":
    main()
