FROM grafana/grafana:9.1.4

ADD configs/provisioning /etc/grafana-provisioning
ADD configs/dashboards /var/lib/grafana-dashboards

USER root

RUN chown -R grafana:472 /etc/grafana-provisioning && \
    chown -R grafana:472 /var/lib/grafana-dashboards

USER grafana
