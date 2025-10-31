#!/usr/bin/env bash
# run_trimgalore_container.sh
#
# This script finds paired FASTQ files in an input directory using the
# `_R1` / `_R2` naming convention and runs Trim Galore in paired-end mode
# inside the Singularity/Apptainer ORAS image you provided.
#
# Usage:
#   ./run_trimgalore_container.sh INPUT_DIR OUTPUT_DIR
#
# Example:
#   ./run_trimgalore_container.sh data_task3 results
#
# Requirements:
#   - Singularity or Apptainer must be available on PATH
#   - Input FASTQ files must use `_R1` / `_R2` in the filename (e.g. sample_R1.fastq.gz)

set -euo pipefail

######################### User-configurable section ##########################
# The ORAS Singularity image you provided (Seqera Wave ORAS registry)
TRIMGALORE_IMAGE="oras://community.wave.seqera.io/library/trim-galore:0.6.10--bc38c9238980c80e"

# Additional Trim Galore options you want by default (kept as an array)
# --paired is required for paired-end, can append more here if desired
TRIMGALORE_OPTS=(--paired)
##############################################################################

log() {
  local msg="$1"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $msg"
  if [[ -n "${LOGFILE:-}" ]]; then
    echo "[$ts] $msg" >> "$LOGFILE"
  fi
}

usage() {
  cat <<EOF
Usage: $0 INPUT_DIR OUTPUT_DIR

Finds files named with the pattern '*_R1*.fastq' or '*_R1*.fastq.gz' in INPUT_DIR,
infers the mate pair by replacing the first occurrence of '_R1' with '_R2',
and runs Trim Galore in paired-end mode inside the Singularity ORAS image
configured in the script.
EOF
  exit 2
}

if [[ ${#} -lt 2 ]]; then
  usage
fi

INPUT_DIR="$1"
OUTPUT_DIR="$2"

if [[ ! -d "$INPUT_DIR" ]]; then
  echo "ERROR: input dir '$INPUT_DIR' does not exist or is not a directory." >&2
  exit 3
fi

if ! command -v singularity >/dev/null 2>&1 && ! command -v apptainer >/dev/null 2>&1; then
  echo "ERROR: Singularity or Apptainer is not available on PATH. Install or load it before running this script." >&2
  exit 4
fi

mkdir -p "$OUTPUT_DIR"
LOGFILE="$OUTPUT_DIR/trimgalore_run.log"
: > "$LOGFILE"

ABS_INPUT=$(readlink -f "$INPUT_DIR")
ABS_OUTPUT=$(readlink -f "$OUTPUT_DIR")

log "Trim Galore run (Singularity-only)"
log "Input directory: $ABS_INPUT"
log "Output directory: $ABS_OUTPUT"
log "Container image: $TRIMGALORE_IMAGE"

# Choose available container front-end (use array form to preserve command + subcommand)
if command -v apptainer >/dev/null 2>&1; then
  CONTAINER_CMD=(apptainer exec)
else
  CONTAINER_CMD=(singularity exec)
fi

found_any=0

  # Find R1 files (handles .fastq and .fastq.gz)
while IFS= read -r -d '' r1file; do
  found_any=1
  r1_relpath=${r1file#"$ABS_INPUT/"}  # Get path relative to input dir
  r1_dirname=$(dirname "$r1_relpath")  # Get subdirectory path if any
  r1_basename=$(basename "$r1file")

  # Enforce the _R1 -> _R2 pattern; only proceed when _R1 is present
  if [[ "$r1_basename" != *"_R1"* ]]; then
    log "SKIP: $r1_basename does not contain the pattern _R1; expecting _R1/_R2 naming."
    continue
  fi

  # infer R2 by replacing the first occurrence of _R1 with _R2
  r2_basename=${r1_basename/_R1/_R2}

  if [[ ! -e "$ABS_INPUT/$r1_dirname/$r2_basename" ]]; then
    log "WARNING: mate file not found for $r1_dirname/$r1_basename -> expected $r2_basename. Skipping."
    continue
  fi

  # Build the command array. Expand container command array safely and use two --bind flags.
  CMD=( "${CONTAINER_CMD[@]}" --bind "$ABS_INPUT":/data --bind "$ABS_OUTPUT":/out "$TRIMGALORE_IMAGE" \
        trim_galore "${TRIMGALORE_OPTS[@]}" "/data/$r1_dirname/$r1_basename" "/data/$r1_dirname/$r2_basename" -o /out )

  # Join for printing (shell-escaped for clarity)
  joined_cmd=$(printf "%q " "${CMD[@]}")
  log "COMMAND: $joined_cmd"

  # Execute the command and record success/failure per pair
  if "${CMD[@]}"; then
    log "SUCCESS: processed pair $r1_basename + $r2_basename"
  else
    log "ERROR: Trim Galore failed on pair $r1_basename + $r2_basename"
  fi

done < <(find "$ABS_INPUT" -type f -iname '*_R1*.fastq*' -print0)

if [[ $found_any -eq 0 ]]; then
  log "No R1 files found in $ABS_INPUT matching pattern '*_R1*.fastq*'"
fi

log "Finished. See log file: $LOGFILE"

exit 0