FROM quay.io/strimzi/kafka:1.0.1-kafka-4.1.2

USER root:root
RUN mkdir -p /opt/kafka/plugins/debezium-postgres
COPY debezium-connector-postgres/ /opt/kafka/plugins/debezium-postgres/
RUN chown -R 1001:0 /opt/kafka/plugins/debezium-postgres \
 && chmod -R g+rwX /opt/kafka/plugins/debezium-postgres
USER 1001
