# Frappe HR (hrms) + ERPNext + Frappe, develop branch, single-container image for Railway.
# Based on frappe_docker images/layered/Containerfile.
ARG FRAPPE_BRANCH=develop
FROM frappe/build:${FRAPPE_BRANCH} AS builder
ARG FRAPPE_BRANCH=develop
ARG FRAPPE_PATH=https://github.com/frappe/frappe
USER frappe
COPY --chown=frappe:frappe apps.json /opt/frappe/apps.json
RUN bench init --apps_path=/opt/frappe/apps.json \
      --frappe-branch=${FRAPPE_BRANCH} --frappe-path=${FRAPPE_PATH} \
      --no-procfile --no-backups --skip-redis-config-generation --verbose \
      /home/frappe/frappe-bench && \
    cd /home/frappe/frappe-bench && \
    echo "{}" > sites/common_site_config.json && \
    find apps -mindepth 1 -path "*/.git" | xargs rm -fr

FROM frappe/base:${FRAPPE_BRANCH} AS backend
USER root
RUN apt-get update && apt-get install --no-install-recommends -y curl ca-certificates && \
    curl -fsSL -o /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && \
    chmod 755 /usr/local/bin/cloudflared && rm -rf /var/lib/apt/lists/*
USER frappe
COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench
WORKDIR /home/frappe/frappe-bench
RUN cp -r sites/assets assets && rm -rf sites/assets
USER root
COPY resources/link-assets.sh /usr/local/bin/link-assets.sh
COPY resources/gunicorn.sh /usr/local/bin/gunicorn.sh
COPY resources/frappe-boot.sh /usr/local/bin/frappe-boot.sh
COPY resources/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/*.sh
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
