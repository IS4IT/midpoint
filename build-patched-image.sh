#!/usr/bin/env bash
#
# Build a midPoint docker image with our local fix to
# provisioning/ucf-impl-connid/.../ConnIdSchemaParser.java applied
# (alphabetical sort of connector-reported attributes before assigning
# displayOrder; see commit 26aae5b on fix/connid-schema-parser-attribute-sort).
#
# The script is idempotent: it re-builds the ucf-impl-connid JAR, downloads the
# matching upstream evolveum/midpoint image, swaps the embedded
# BOOT-INF/lib/ucf-impl-connid-<version>.jar inside midpoint.jar (preserving
# Spring Boot's STORED method for nested JARs), and tags the result as
#   evolveum/midpoint:<version>-attr-sort
#
# Defaults to whatever <version> the current checkout reports. Override with
# --version, --base-tag (the upstream tag to layer on), or --output-tag.
#
# Usage:
#   ./build-patched-image.sh
#   ./build-patched-image.sh --version 4.10.4 --base-tag 4.10.4 --output-tag 4.10.4-attr-sort
#   ./build-patched-image.sh --no-build      # skip the Maven step, reuse target/
#
# Requires: mvn, docker, unzip, zip.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
cd "${SCRIPT_DIR}"

VERSION=""
BASE_TAG=""
OUTPUT_TAG=""
DO_BUILD=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)      VERSION=$2; shift 2 ;;
        --base-tag)     BASE_TAG=$2; shift 2 ;;
        --output-tag)   OUTPUT_TAG=$2; shift 2 ;;
        --no-build)     DO_BUILD=false; shift ;;
        -h|--help)
            sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "ERROR: unknown argument '$1'" >&2
            exit 2 ;;
    esac
done

# Resolve project version if not supplied. mvn is the canonical source -
# parsing pom.xml directly is fragile (the first <version> is spring-boot).
if [[ -z "${VERSION}" ]]; then
    echo "==> Reading project version via Maven"
    VERSION=$(mvn -q -N help:evaluate -Dexpression=project.version -DforceStdout)
    if [[ -z "${VERSION}" || "${VERSION}" == *"ERROR"* ]]; then
        echo "ERROR: could not determine project version automatically; pass --version <X.Y.Z>" >&2
        exit 1
    fi
fi
BASE_TAG=${BASE_TAG:-${VERSION}}
OUTPUT_TAG=${OUTPUT_TAG:-${VERSION}-attr-sort}

BASE_IMAGE="evolveum/midpoint:${BASE_TAG}"
OUTPUT_IMAGE="evolveum/midpoint:${OUTPUT_TAG}"
MODULE_JAR="${SCRIPT_DIR}/provisioning/ucf-impl-connid/target/ucf-impl-connid-${VERSION}.jar"
EMBEDDED_PATH="BOOT-INF/lib/ucf-impl-connid-${VERSION}.jar"

echo "==> Project version : ${VERSION}"
echo "==> Base image      : ${BASE_IMAGE}"
echo "==> Output image    : ${OUTPUT_IMAGE}"
echo "==> Module JAR      : ${MODULE_JAR}"

# Sanity check the patch is actually present in the working tree. If someone
# has rebased it away or the file has reverted to upstream, abort loudly
# rather than baking a no-op image.
PARSER=provisioning/ucf-impl-connid/src/main/java/com/evolveum/midpoint/provisioning/ucf/impl/connid/ConnIdSchemaParser.java
if ! grep -q "sortedAttributeInfos.sort(Comparator.comparing(AttributeInfo::getName))" "${PARSER}"; then
    echo "ERROR: the attribute-sort patch is missing from ${PARSER}" >&2
    echo "       Make sure you are on a branch that contains the fix." >&2
    exit 1
fi

if $DO_BUILD; then
    echo "==> Building ucf-impl-connid JAR"
    mvn -ntp -pl provisioning/ucf-impl-connid -am -DskipTests package
fi
if [[ ! -f "${MODULE_JAR}" ]]; then
    echo "ERROR: ${MODULE_JAR} not found; run without --no-build" >&2
    exit 1
fi

# Stage everything under a per-run tmpdir so re-runs and parallel runs don't
# fight over the same files, and cleanup is automatic on success or failure.
WORK=$(mktemp -d -t midpoint-attr-sort-XXXXXX)
trap 'rm -rf "${WORK}"' EXIT
echo "==> Staging in ${WORK}"

echo "==> Extracting midpoint.jar from ${BASE_IMAGE}"
docker pull "${BASE_IMAGE}" >/dev/null
CID=$(docker create "${BASE_IMAGE}")
docker cp "${CID}:/opt/midpoint/lib/midpoint.jar" "${WORK}/midpoint.jar"
docker rm "${CID}" >/dev/null

# Verify the upstream image actually carries the embedded module jar at the
# path we're going to overwrite. If the layout ever changes upstream this
# is where we want to fail clearly. Capture the listing once instead of
# piping unzip -> grep -q: grep -q closes the pipe on first match, unzip
# then dies with SIGPIPE, and `set -o pipefail` would report the pipeline
# as failed even though the match succeeded.
LISTING=$(unzip -lv "${WORK}/midpoint.jar")
if ! grep -qF -- "${EMBEDDED_PATH}" <<< "${LISTING}"; then
    echo "ERROR: ${EMBEDDED_PATH} not found inside ${BASE_IMAGE}'s midpoint.jar" >&2
    echo "       The upstream uber-jar layout may have changed - inspect manually." >&2
    exit 1
fi

echo "==> Swapping ${EMBEDDED_PATH} (STORED, required by Spring Boot loader)"
mkdir -p "${WORK}/staging/BOOT-INF/lib"
cp "${MODULE_JAR}" "${WORK}/staging/${EMBEDDED_PATH}"
( cd "${WORK}/staging" && zip -0 -X "${WORK}/midpoint.jar" "${EMBEDDED_PATH}" >/dev/null )

# Cross-check that the swap kept the STORED method. If zip ever decides to
# deflate, Spring Boot's nested-jar loader will fail at runtime. Same
# pipefail/SIGPIPE caveat as above - capture the listing first, then awk.
LISTING_AFTER=$(unzip -lv "${WORK}/midpoint.jar")
METHOD=$(awk -v p="${EMBEDDED_PATH}" '$0 ~ p {print $2; exit}' <<< "${LISTING_AFTER}")
if [[ "${METHOD}" != "Stored" ]]; then
    echo "ERROR: embedded jar was written with compression method '${METHOD}', expected 'Stored'" >&2
    exit 1
fi

echo "==> Building ${OUTPUT_IMAGE}"
cat > "${WORK}/Dockerfile" <<DOCKERFILE
FROM ${BASE_IMAGE}
COPY midpoint.jar /opt/midpoint/lib/midpoint.jar
DOCKERFILE
docker build -t "${OUTPUT_IMAGE}" "${WORK}" >/dev/null

echo
echo "Built ${OUTPUT_IMAGE}"
docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}  ({{.CreatedSince}})' "${OUTPUT_IMAGE}"
echo
echo "Point the connector-sap rig at it:"
echo "  echo 'MP_VER=${OUTPUT_TAG}' > /Volumes/Daten/git/connector-sap/docker/.env  # or edit"
echo "  docker compose -f /Volumes/Daten/git/connector-sap/docker/docker-compose.yml up -d --no-deps mp_server"
