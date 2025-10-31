#!/bin/bash
#SBATCH --account=PAS2880
#SBATCH --mail-type=FAIL
#SBATCH --output=slurm-star-index-%j.out
set -euo pipefail

# STAR container (ORAS image)
STAR_CONTAINER=oras://community.wave.seqera.io/library/star:2.7.11b--84fcc19fdfab53a4

# Copy the placeholder variables. Defaults are provided so the script can be
# invoked without arguments when run from the `GA5/` directory in this repo.
indir="${1:-$(readlink -f "$(dirname "$0")/../data/ref") }"
outdir="${2:-$(readlink -f "$(dirname "$0")/../results/star/index") }"

# Tuneable parameters
threads=${3:-4}
sjdbOverhang=${4:-100}

echo "# Starting script star_index.sh"
date
echo "# Input dir:    $indir"
echo "# Output dir:   $outdir"
echo "# Threads:      $threads"
echo "# sjdbOverhang: $sjdbOverhang"
echo

mkdir -p "$outdir"
mkdir -p "$outdir/logs"

# Locate the genome FASTA (prefer uncompressed fasta if available)
genome_fasta=$(find "$indir" -maxdepth 1 -type f \( -iname '*.fa' -o -iname '*.fasta' -o -iname '*.fna' -o -iname '*.fa.gz' -o -iname '*.fasta.gz' \) | head -n1 || true)
annotation_gtf=$(find "$indir" -maxdepth 1 -type f -iname '*.gtf' | head -n1 || true)

if [[ -z "$genome_fasta" ]]; then
  echo "ERROR: no genome FASTA found in $indir (expected .fa/.fasta/.fna)" >&2
  exit 2
fi

echo "# Found genome FASTA: $genome_fasta"
if [[ -n "$annotation_gtf" ]]; then
  echo "# Found annotation GTF: $annotation_gtf"
else
  echo "# No GTF found in $indir; STAR will build the index without splice junction annotations"
fi

echo
echo "# Running STAR genomeGenerate inside container"

# Use apptainer/singularity if available. Prefer apptainer if present.
if command -v apptainer >/dev/null 2>&1; then
  RUNTIME_CMD=(apptainer exec)
elif command -v singularity >/dev/null 2>&1; then
  RUNTIME_CMD=(singularity exec)
else
  echo "ERROR: apptainer or singularity not found on PATH" >&2
  exit 3
fi

# Build the STAR command (paths inside container will use /data and /out)
STAR_CMD=( "${RUNTIME_CMD[@]}" --bind "$indir":/data --bind "$outdir":/out "$STAR_CONTAINER" \
  STAR --runThreadN "$threads" --runMode genomeGenerate --genomeDir /out \
  --genomeFastaFiles /data/"$(basename "$genome_fasta")" )

if [[ -n "$annotation_gtf" ]]; then
  STAR_CMD+=( --sjdbGTFfile /data/"$(basename "$annotation_gtf")" --sjdbOverhang "$sjdbOverhang" )
fi

printf "# COMMAND: %q \n" "${STAR_CMD[@]}"

if "${STAR_CMD[@]}"; then
  echo
  echo "# STAR genome index created successfully"
else
  echo
  echo "ERROR: STAR genomeGenerate failed" >&2
  exit 4
fi

echo
echo "# STAR version:"
"${RUNTIME_CMD[@]}" --bind "$indir":/data --bind "$outdir":/out "$STAR_CONTAINER" STAR --version || true

echo "# Finished:"
date
