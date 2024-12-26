FROM grafana/grafana:11.4.0

ADD configs/provisioning /etc/grafana-provisioning
ADD configs/dashboards /var/lib/grafana-dashboards

USER root

RUN chown -R grafana:472 /etc/grafana-provisioning && \
    chown -R grafana:472 /var/lib/grafana-dashboards

USER grafana
