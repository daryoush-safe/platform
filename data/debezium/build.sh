set -euo pipefail
cd "$(dirname "$0")"

DEBEZIUM_VERSION="${DEBEZIUM_VERSION:-3.5.2.Final}"
IMAGE="${IMAGE:-debezium-connect:3.5.2}"
TARBALL="debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz"
BASE_URL="https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/${DEBEZIUM_VERSION}"

if [ ! -d debezium-connector-postgres ]; then
  echo ">> downloading ${TARBALL}"
  curl -fsSL -o "${TARBALL}" "${BASE_URL}/${TARBALL}"
  tar xzf "${TARBALL}"
fi

echo ">> docker build ${IMAGE}"
docker build -t "${IMAGE}" .

echo ">> importing into k3s containerd (needs sudo)"
docker save "${IMAGE}" | sudo k3s ctr images import -

echo ">> done: ${IMAGE} is in containerd. KafkaConnect uses imagePullPolicy IfNotPresent."
