import wave
import struct
import argparse
from pathlib import Path

def write_uint24_le(f, n):
    f.write(bytes((n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF)))

def pcm16_to_pcm8_signed(sample):
    x = (sample >> 8) + 128
    return max(0, min(255, x))

def wav_to_pda(in_wav, out_pda, target_bits=16):
    if not isinstance(in_wav,Path):
        in_wav = Path(in_wav)
    if not isinstance(out_pda,Path):
        out_pda = Path(out_pda)

    with wave.open(str(in_wav), "rb") as wf:
        nchannels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        samplerate = wf.getframerate()
        nframes = wf.getnframes()
        raw = wf.readframes(nframes)

    if nchannels not in (1, 2):
        raise ValueError("Only mono or stereo WAV files are supported")

    if sampwidth == 1:
        s8 = raw
        samples16 = [(b - 128) << 8 for b in s8]
    elif sampwidth == 2:
        samples16 = list(struct.unpack("<{}h".format(len(raw) // 2), raw))
    elif sampwidth == 3:
        samples16 = []
        for i in range(0, len(raw), 3):
            b = raw[i:i+3]
            v = int.from_bytes(b + (b'\xff' if b[2] & 0x80 else b'\x00'), "little", signed=True)
            samples16.append(v >> 8)
    elif sampwidth == 4:
        ints = struct.unpack("<{}i".format(len(raw) // 4), raw)
        samples16 = [max(-32768, min(32767, v >> 16)) for v in ints]
    else:
        raise ValueError("Unsupported WAV bit depth")

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
    ap = argparse.ArgumentParser()
    ap.add_argument("--input")
    ap.add_argument("--output")
    ap.add_argument("--bits", type=int, choices=[8, 16], default=16)
    args = ap.parse_args()
    wavfiles = []
    pdafiles = []
    if args.input is None:
        # if input is None, ignore the output arguments
        wavfiles = [Path(x) for x in Path.cwd().glob('*.wav')]
        pdafiles = [x.with_suffix(".pda") for x in wavfiles]
    else:
        wavfiles = [args.input]
        pdafiles = [args.output]

    
    print(wavfiles,pdafiles)

    [wav_to_pda(x, y, args.bits) for (x,y) in zip(wavfiles,pdafiles)]

if __name__ == "__main__":
    main()