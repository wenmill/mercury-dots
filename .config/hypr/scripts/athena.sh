#!/usr/bin/env bash
# Athena — voice conversation with Hermes.
#
# Opens a Hermes chat in a floating terminal. Push-to-talk with the record key
# (default ctrl+b, set by voice.record_key in ~/.hermes/config.yaml): your mic
# audio goes straight to Hermes, which transcribes it (STT: local faster-whisper
# by default) and hands the text to the model. The assistant identifies as
# "Athena" via ~/.hermes/SOUL.md. Enable voice.auto_tts in the Hermes config for
# spoken replies.
#
# NOTE: Hermes' voice pipeline TRANSCRIBES audio (whisper) before the model sees
# it — it does not pass the raw waveform to the model. To get an audio-native
# model doing the listening, set stt.provider to "mistral" (Voxtral) or "openai"
# (gpt-4o-transcribe) in the Hermes config; true raw-audio-to-model would need a
# Hermes core change and an audio-capable model.
export HERMES_HOME="$HOME/.hermes"

# If an Athena terminal is already open, just focus it.
existing=$(hyprctl clients -j 2>/dev/null | jq -r 'first(.[] | select(.class=="athena") | .address) // empty' 2>/dev/null)
if [ -n "$existing" ]; then
    hyprctl dispatch focuswindow "address:$existing" >/dev/null 2>&1
    exit 0
fi

# -m gemma-athena selects the no-reasoning alias (custom_providers: athena-fast)
# so replies come back fast for speech; the underlying model is the same
# gemma-active llama-server, coding sessions on gemma-active.gguf still reason.
exec kitty --class athena --title "Athena" \
    -o remember_window_size=no \
    -o initial_window_width=900 -o initial_window_height=620 \
    hermes --continue athena -m gemma-athena chat
