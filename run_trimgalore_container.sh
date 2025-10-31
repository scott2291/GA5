#!/usr/bin/env bash
"""
run_trimgalore_container.sh

Usage:
  ./run_trimgalore_container.sh /path/to/input_dir /path/to/output_dir [docker|singularity]

Description:
  Loop over R1 FASTQ files in the input directory and run Trim Galore on each pair
  in paired-end mode using  a container. The script will try to use the requested
  container runtime (docker or singularity). If not provided, it will prefer
  Singularity when available, else Docker.

  The script expects paired files to follow a naming convention where the mate
  pair can be inferred by replacing `_R1` with `_R2` in the filename (case
  sensitive). Handles gzipped or plain FASTQ filenames (e.g. `*_R1.fastq.gz` or
  `*_R1.fastq`).

Notes:
  - Default Trim Galore image (change `TRIMGALORE_IMAGE` below if you prefer):
      quay.io/biocontainers/trim-galore:0.6.7--py36hdb2a3b8_0
  - For Docker, directories are bind-mounted into the container at /data (input)
    and /out (output).
  - For Singularity/Apptainer the script accepts full image URIs (e.g. ORAS
    `oras://...` or Docker `docker://...`) and will pass them directly to
    `singularity exec`/`apptainer exec`.

Logging:
  A log file `trimgalore_run.log` will be created in the output directory and
  each step will be timestamped.
"""

set -euo pipefail

############# Configuration (edit if you want a different image) #############
# Use the Singularity/ORAS image provided by the user (Seqera Wave ORAS registry)
TRIMGALORE_IMAGE="oras://community.wave.seqera.io/library/trim-galore:0.6.10--bc38c9238980c80e"
DEFAULT_RUNTIME="singularity"   # preferred runtime when available
###############################################################################

log() {
  local msg="$1"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $msg"
  # also append to logfile if LOGFILE is set
  if [[ -n "${LOGFILE:-}" ]]; then
    echo "[$ts] $msg" >> "$LOGFILE"
  fi
}

usage() {
  cat <<EOF
Usage: $0 INPUT_DIR OUTPUT_DIR [docker|singularity]

Example:
  $0 ./data ./trimmed docker

This will run Trim Galore in paired-end mode for each R1 file in INPUT_DIR and
write outputs to OUTPUT_DIR.
EOF
  exit 2
}

if [[ ${#} -lt 2 ]]; then
  usage
fi

INPUT_DIR="$1"
OUTPUT_DIR="$2"
REQUESTED_RUNTIME="${3:-}"

if [[ ! -d "$INPUT_DIR" ]]; then
  echo "ERROR: input dir '$INPUT_DIR' does not exist or is not a directory." >&2
  exit 3
fi

mkdir -p "$OUTPUT_DIR"
LOGFILE="$OUTPUT_DIR/trimgalore_run.log"
: > "$LOGFILE"

ABS_INPUT=$(readlink -f "$INPUT_DIR")
ABS_OUTPUT=$(readlink -f "$OUTPUT_DIR")

# detect runtime
RUNTIME=""
if [[ -n "$REQUESTED_RUNTIME" ]]; then
  case "$REQUESTED_RUNTIME" in
    docker|singularity) RUNTIME="$REQUESTED_RUNTIME" ;;
    *) echo "Unknown runtime '$REQUESTED_RUNTIME'. Use 'docker' or 'singularity'." >&2; exit 4 ;;
  esac
else
  # prefer singularity when available, else docker
  if command -v singularity >/dev/null 2>&1; then
    RUNTIME="singularity"
  elif command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
  else
    echo "Neither singularity nor docker were found in PATH. Please install one or provide a runtime argument." >&2
    exit 5
  fi
fi

log "Starting Trim Galore run"
log "Input: $ABS_INPUT"
log "Output: $ABS_OUTPUT"
log "Using container runtime: $RUNTIME"
log "Container image: $TRIMGALORE_IMAGE"

# If the configured image is an ORAS/Apptainer URI, Docker cannot run it directly.
if [[ "$RUNTIME" == "docker" && "$TRIMGALORE_IMAGE" == oras://* ]]; then
  echo "ERROR: the configured image is an ORAS URI which Docker cannot run directly." >&2
  echo "Please run with Singularity or provide a Docker-compatible image tag." >&2
  exit 6
fi

run_trim_docker() {
  local r1_basename="$1"
  local r2_basename="$2"
  log "Running Docker Trim Galore on $r1_basename + $r2_basename"
  docker run --rm \
    -v "$ABS_INPUT":/data:ro \
    -v "$ABS_OUTPUT":/out \
    "$TRIMGALORE_IMAGE" \
    trim_galore --paired "/data/$r1_basename" "/data/$r2_basename" -o /out
}

run_trim_singularity() {
  local r1_basename="$1"
  local r2_basename="$2"
  log "Running Singularity Trim Galore on $r1_basename + $r2_basename"
  # For ORAS or other Apptainer transports, pass the image URI directly to singularity
  singularity exec --bind "$ABS_INPUT":/data,"$ABS_OUTPUT":/out "$TRIMGALORE_IMAGE" \
    trim_galore --paired "/data/$r1_basename" "/data/$r2_basename" -o /out
}

# loop over R1 files safely (handles spaces)
found_any=0
while IFS= read -r -d '' r1file; do
  found_any=1
  r1_basename=$(basename "$r1file")
  # infer R2 by replacing the first occurrence of the pattern `_R1` with `_R2`
  # This enforces the _R1/_R2 convention (e.g. sample_R1.fastq.gz -> sample_R2.fastq.gz)
  r2_basename=${r1_basename/_R1/_R2}

  # check R2 exists
  if [[ ! -e "$ABS_INPUT/$r2_basename" ]]; then
    log "WARNING: mate file not found for $r1_basename -> expected $r2_basename. Skipping."
    continue
  fi

  # run with chosen runtime
  if [[ "$RUNTIME" == "docker" ]]; then
    run_trim_docker "$r1_basename" "$r2_basename"
  else
    run_trim_singularity "$r1_basename" "$r2_basename"
  fi

  log "Completed processing pair: $r1_basename + $r2_basename"
done < <(find "$ABS_INPUT" -maxdepth 1 -type f -iname '*_R1*.fastq*' -print0)

if [[ $found_any -eq 0 ]]; then
  log "No R1 files found in $ABS_INPUT. Nothing to do."
fi

log "All done. Logs at $LOGFILE"

exit 0
