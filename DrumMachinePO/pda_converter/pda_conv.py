import argparse
from pathlib import Path
import struct
import soundfile as sf
import numpy as np

def write_uint24_le(f, n):
    f.write(bytes((n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF)))

def pcm16_to_pcm8_signed(sample):
    x = (sample >> 8) + 128
    return max(0, min(255, x))

def read_audio(path):
    # soundfile handles WAV/AIFF formats natively
    data, samplerate = sf.read(path, dtype='int16', always_2d=True)
    nchannels = data.shape[1]
    samples16 = data.flatten().tolist()
    return nchannels, int(samplerate), samples16

def audio_to_pda(in_file, out_pda, target_bits=16):
    in_file = Path(in_file)
    out_pda = Path(out_pda)

    nchannels, samplerate, samples16 = read_audio(in_file)

    if target_bits == 8:
        fmt = 0 if nchannels == 1 else 1
        payload = bytes(pcm16_to_pcm8_signed(s) for s in samples16)
    elif target_bits == 16:
        fmt = 2 if nchannels == 1 else 3
        payload = struct.pack("<{}h".format(len(samples16)), *samples16)
    else:
        raise ValueError("target_bits must be 8 or 16")

    with open(out_pda, "wb") as f:
        f.write(b"Playdate AUD")
        write_uint24_le(f, samplerate)
        f.write(bytes([fmt]))
        f.write(payload)

def main():
    ap = argparse.ArgumentParser(description="Convert audio to Playdate .pda")
    ap.add_argument("--input", help="Input audio file")
    ap.add_argument("--output", help="Output .pda file")
    ap.add_argument("--bits", type=int, choices=[8, 16], default=16)
    
    args = ap.parse_args()

    if args.input is None:
        inputs = []
        for ext in ("*.wav", "*.aif", "*.aiff"):
            inputs.extend(Path.cwd().glob(ext))
        if not inputs:
            print("No audio files found in current directory.")
            return
        for inp in inputs:
            print(f"Converting {inp}...")
            audio_to_pda(inp, inp.with_suffix(".pda"), args.bits)
    else:
        if args.output is None:
            raise ValueError("You must provide --output when using --input")
        audio_to_pda(args.input, args.output, args.bits)
        print(f"Converted {args.input} to {args.output}")

if __name__ == "__main__":
    main()