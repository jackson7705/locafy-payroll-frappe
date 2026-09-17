#!/bin/bash
# Single-container Frappe boot: site bootstrap, then nginx + gunicorn + socketio + scheduler + worker + cloudflared.
set -e
BENCH=/home/frappe/frappe-bench; cd $BENCH
export PATH=$BENCH/env/bin:$PATH
: "${SITE_NAME:?}" "${DB_HOST:?}" "${DB_ROOT_PASSWORD:?}" "${REDIS_HOST:?}" "${ADMIN_PASSWORD:?}"
DB_PORT=${DB_PORT:-3306}; REDIS_PORT=${REDIS_PORT:-6379}

/usr/local/bin/link-assets.sh true
# The volume mounted at sites/ hides the image copy of apps.txt; rebuild it from apps/.
ls apps | grep -vE "^\." > sites/apps.txt
mkdir -p logs
cat > sites/common_site_config.json <<JSON
{"db_host": "$DB_HOST", "db_port": $DB_PORT,
 "redis_cache": "redis://$REDIS_HOST:$REDIS_PORT/0", "redis_queue": "redis://$REDIS_HOST:$REDIS_PORT/1", "redis_socketio": "redis://$REDIS_HOST:$REDIS_PORT/1",
 "socketio_port": 9000, "webserver_port": 8000, "default_site": "$SITE_NAME", "server_script_enabled": true}
JSON

echo "Waiting for MariaDB at $DB_HOST:$DB_PORT ..."
for i in $(seq 1 90); do
  python3 - "$DB_HOST" "$DB_PORT" <<'PY' && break
import socket,sys; s=socket.socket(socket.AF_INET6 if ':' in socket.getaddrinfo(sys.argv[1],None)[0][4][0] else socket.AF_INET); s.settimeout(2); s.connect((sys.argv[1],int(sys.argv[2])))
PY
  sleep 2
done

if [ ! -f "sites/$SITE_NAME/site_config.json" ]; then
  echo "Creating site $SITE_NAME"
  bench new-site "$SITE_NAME" --db-root-username root --db-root-password "$DB_ROOT_PASSWORD" \
    --mariadb-user-host-login-scope=% --admin-password "$ADMIN_PASSWORD" --install-app erpnext --install-app hrms --set-default
  bench --site "$SITE_NAME" set-config host_name "https://$SITE_NAME"
  if [ -n "$WIZARD_EMAIL" ]; then
    echo "Running setup wizard"
    bench --site "$SITE_NAME" execute frappe.desk.page.setup_wizard.setup_wizard.setup_complete --kwargs "{\"args\": {
      \"language\": \"English\", \"country\": \"${WIZARD_COUNTRY:-United States}\", \"timezone\": \"${WIZARD_TIMEZONE:-America/Chicago}\",
      \"currency\": \"${WIZARD_CURRENCY:-USD}\", \"full_name\": \"${WIZARD_FULL_NAME:-Administrator}\", \"email\": \"$WIZARD_EMAIL\",
      \"password\": \"$ADMIN_PASSWORD\", \"company_name\": \"${WIZARD_COMPANY:-Company}\", \"company_abbr\": \"${WIZARD_COMPANY_ABBR:-CO}\",
      \"chart_of_accounts\": \"Standard\", \"fy_start_date\": \"${WIZARD_FY_START:-2026-01-01}\", \"fy_end_date\": \"${WIZARD_FY_END:-2026-12-31}\",
      \"module_accounting\": 1, \"module_leave_attendance\": 1, \"module_payroll\": 1, \"module_recruitment\": 1, \"module_performance\": 1}}"
  fi
else
  # Containers get a new private IP on every deploy. Make sure the site DB user may connect from any host.
  python3 - "$SITE_NAME" "$DB_HOST" "$DB_PORT" "$DB_ROOT_PASSWORD" <<'PY'
import json, sys, MySQLdb
site, host, port, rootpw = sys.argv[1:5]
cfg = json.load(open(f"sites/{site}/site_config.json")); db, pw = cfg["db_name"], cfg["db_password"]
conn = MySQLdb.connect(host=host, port=int(port), user="root", passwd=rootpw); cur = conn.cursor()
cur.execute(f"CREATE USER IF NOT EXISTS '{db}'@'%%' IDENTIFIED BY %s", (pw,))
cur.execute(f"ALTER USER '{db}'@'%%' IDENTIFIED BY %s", (pw,))
cur.execute(f"GRANT ALL PRIVILEGES ON `{db}`.* TO '{db}'@'%%'")
cur.execute("FLUSH PRIVILEGES"); conn.commit(); print("DB user host scope ensured for", db)
PY
  echo "Site exists; running migrate"
  bench --site "$SITE_NAME" migrate
fi
# Pin the encryption key before any long-running process starts; otherwise each process
# lazily generates its own and encrypted values (API secrets, email passwords) break.
if ! grep -q '"encryption_key"' "sites/$SITE_NAME/site_config.json"; then
  bench --site "$SITE_NAME" set-config encryption_key "$(python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')"
fi
echo "$SITE_NAME" > sites/currentsite.txt

export BACKEND=127.0.0.1:8000 SOCKETIO=127.0.0.1:9000 FRAPPE_SITE_NAME_HEADER="$SITE_NAME" UPSTREAM_REAL_IP_HEADER=CF-Connecting-IP
/usr/local/bin/nginx-entrypoint.sh &
/usr/local/bin/gunicorn.sh &
node apps/frappe/socketio.js &
bench schedule &
bench worker --queue short,default,long &
if [ -n "$TUNNEL_TOKEN" ]; then cloudflared tunnel --no-autoupdate run --token "$TUNNEL_TOKEN" & fi
wait -n
echo "A process exited; shutting down"; exit 1
