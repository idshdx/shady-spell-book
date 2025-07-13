#!/bin/bash

set -euo pipefail

# --- Default flags ---
VIDEO_URL=""
SPELLCHECK=false
GRAMMARCHECK=false
TRANSLATE=false
LANG_CODE="en_US"
OUTDIR="./out"

# --- Parse CLI args ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        http*) VIDEO_URL="$1" ;;
        --spellcheck) SPELLCHECK=true ;;
        --grammar) GRAMMARCHECK=true ;;
        --translate) TRANSLATE=true ;;
        --lang) LANG_CODE="$2"; shift ;;
        --outdir) OUTDIR="$2"; shift ;;
        *) echo "[ERROR] Unknown option: $1" && exit 1 ;;
    esac
    shift
done

if [[ -z "$VIDEO_URL" ]]; then
    echo "Usage: $0 <youtube_url> [--spellcheck] [--grammar] [--translate] [--lang <lang_code>] [--outdir <dir>]"
    exit 1
fi

# --- Setup workspace ---
VIDEO_ID=$(yt-dlp --get-id "$VIDEO_URL")
WORKDIR="$OUTDIR/$VIDEO_ID"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

LOGFILE="$VIDEO_ID.log"
exec > >(tee -i "$LOGFILE") 2>&1

echo "[INFO] Processing: $VIDEO_URL"
echo "[INFO] Working dir: $WORKDIR"

# --- Step 1: Try to get YouTube transcript ---
echo "[STEP] Checking for YouTube captions..."
yt-dlp --write-auto-sub --sub-lang en --skip-download "$VIDEO_URL" > /dev/null 2>&1

TRANSCRIPT_FILE=$(find . -name "*.vtt" | head -n 1)
OUTPUT_TXT="${VIDEO_ID}.txt"

if [[ -f "$TRANSCRIPT_FILE" ]]; then
    echo "[OK] Found auto captions."
    ffmpeg -i "$TRANSCRIPT_FILE" -f srt -y "${VIDEO_ID}.srt" > /dev/null 2>&1
    ffmpeg -i "${VIDEO_ID}.srt" "$OUTPUT_TXT" > /dev/null 2>&1 || cp "${VIDEO_ID}.srt" "$OUTPUT_TXT"
else
    echo "[WARN] No captions found. Falling back to Whisper..."
    yt-dlp -x --audio-format mp3 "$VIDEO_URL" -o "${VIDEO_ID}.%(ext)s"
    whisper "${VIDEO_ID}.mp3" --output_format txt
    mv "${VIDEO_ID}.mp3.txt" "$OUTPUT_TXT"
fi

# --- Step 2: Spellcheck (Hunspell) ---
if $SPELLCHECK; then
    if command -v hunspell >/dev/null 2>&1; then
        echo "[STEP] Running Hunspell ($LANG_CODE)..."
        cat "$OUTPUT_TXT" | hunspell -l -d "$LANG_CODE" | sort | uniq > "${VIDEO_ID}_misspelled.txt"
        echo "[INFO] Misspelled words saved in ${VIDEO_ID}_misspelled.txt"
    else
        echo "[WARN] Hunspell not found. Skipping spellcheck."
    fi
fi

# --- Step 3: Grammar check (LanguageTool) ---
if $GRAMMARCHECK; then
    if command -v languagetool >/dev/null 2>&1; then
        echo "[STEP] Running LanguageTool grammar check..."
        languagetool -l "${LANG_CODE%%_*}" "$OUTPUT_TXT" > "${VIDEO_ID}_grammar_report.txt"
        echo "[INFO] Grammar report saved in ${VIDEO_ID}_grammar_report.txt"
    else
        echo "[WARN] LanguageTool CLI not found. Skipping grammar check."
    fi
fi

# --- Step 4: Translation (translate-shell) ---
if $TRANSLATE; then
    if command -v trans >/dev/null 2>&1; then
        echo "[STEP] Translating transcript to Romanian..."
        cat "$OUTPUT_TXT" | trans :ro -brief > "${VIDEO_ID}_ro.txt"
        echo "[INFO] Translation saved in ${VIDEO_ID}_ro.txt"
    else
        echo "[WARN] translate-shell not found. Skipping translation."
    fi
fi

echo "[DONE] Processing complete. Output directory: $WORKDIR"