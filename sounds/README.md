# Beyond All Reason Advisor Sounds

The sound files in this folder were created by [piper-tts](https://pypi.org/project/piper-tts/) which is provided by
[piper1-gpl](https://github.com/OHF-Voice/piper1-gpl). On [piper-samples](https://rhasspy.github.io/piper-samples/)
you can try out different settings for piper which also provides download links for the models on
[Hugging Face](https://huggingface.co/rhasspy/piper-voices).

Each `<name>.wav` was generated from the text in `<name>.txt` (raw phonemes in `[[...]]` override the
pronunciation) with piper-tts 1.8.0 and the voice `en_US-amy-medium`
([files](https://huggingface.co/rhasspy/piper-voices/tree/main/en/en_US/amy/medium)), then loudness-matched to BAR's
own voice lines.

## Setup

`requirements.txt` pins the exact package versions the lines were made with (tested with Python 3.12). In this folder:

```
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Then download `en_US-amy-medium.onnx` and `en_US-amy-medium.onnx.json` from the Hugging Face link above, and keep
them together in one folder outside the repository.

## Re-creating a line

Edit `<name>.txt` if needed, then run, with the venv activated (`source .venv/bin/activate`):

```
python -I make_voice_line.py --voice <path to>/en_US-amy-medium.onnx <name>.txt
```

Piper's output varies between runs, so listen to a re-created line before keeping it.

## Writing the text

- Write numbers as words and join them to "tech" with a dash ("Tech-one", "Consider tech-three"). Without the dash,
  Piper pauses after the number.
- Write "anti air" and "anti nuke" without a dash.
- Raw phonemes in `[[...]]` override the pronunciation, e.g. `[[kənstɹˈʌktʰɚ]]` for "constructor" (otherwise the second
  t gets swallowed). The script prints the phonemes it used, so you can check how a text was read.

## AI policy

These are generated audio files. BAR's [AI policy](https://github.com/beyond-all-reason/Beyond-All-Reason/blob/master/AI_POLICY.md)
does not accept AI-generated media, so they are not meant to be submitted to the game.
