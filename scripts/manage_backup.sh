#!/usr/bin/env bash
set -euo pipefail

# ===============================
# CONFIGURAÇÃO - variáveis de ambiente obrigatórias
# ===============================
PRIMARY_HEALTH_URL="${PRIMARY_HEALTH_URL:-http://168.75.97.255/ping}"
PRIMARY_INSTANCE_OCID="${PRIMARY_INSTANCE_OCID:?Need to set PRIMARY_INSTANCE_OCID}"
BACKUP_INSTANCE_OCID="${BACKUP_INSTANCE_OCID:?Need to set BACKUP_INSTANCE_OCID}"
COMPARTMENT_OCID="${COMPARTMENT_OCID:?Need to set COMPARTMENT_OCID}"
DO_ACTION="${DO_ACTION:-true}"

# Tentativas de healthcheck HTTP
PING_RETRIES="${PING_RETRIES:-3}"
PING_DELAY="${PING_DELAY:-3}"  # segundos entre tentativas

# ===============================
# FUNÇÕES AUXILIARES
# ===============================

function check_http_primary() {
    local success_count=0
    for ((i=1; i<=PING_RETRIES; i++)); do
        echo "→ Tentativa $i de $PING_RETRIES: verificando $PRIMARY_HEALTH_URL..." >&2
        if curl -sf -o /dev/null "$PRIMARY_HEALTH_URL"; then
            ((success_count++))
        fi
        sleep "$PING_DELAY"
    done

    if ((success_count > 0)); then
        echo "true"
    else
        echo "false"
    fi
}

function get_instance_state() {
    local instance_id="$1"
    oci compute instance get \
        --instance-id "$instance_id" \
        --query 'data."lifecycle-state"' \
        --raw-output \
        --config-file "$OCI_CONFIG_FILE"
}

function start_instance() {
    local instance_id="$1"
    if [ "$DO_ACTION" = true ]; then
        echo "🚀 Iniciando instância $instance_id..."
        oci compute instance action \
            --instance-id "$instance_id" \
            --action START \
            --wait-for-state RUNNING \
            --config-file "$OCI_CONFIG_FILE"
    else
        echo "[DEBUG] Would start instance $instance_id"
    fi
}

function stop_instance() {
    local instance_id="$1"
    if [ "$DO_ACTION" = true ]; then
        echo "🛑 Parando instância $instance_id..."
        oci compute instance action \
            --instance-id "$instance_id" \
            --action STOP \
            --wait-for-state STOPPED \
            --config-file "$OCI_CONFIG_FILE"
    else
        echo "[DEBUG] Would stop instance $instance_id"
    fi
}

# ===============================
# CRIAÇÃO DE CONFIGURAÇÃO OCI AUTOMÁTICA
# ===============================

mkdir -p "$(dirname "$OCI_CONFIG_FILE")"
cat > "$OCI_CONFIG_FILE" <<EOF
[DEFAULT]
user=${OCI_USER:?Need to set OCI_USER}
fingerprint=${OCI_FINGERPRINT:?Need to set OCI_FINGERPRINT}
tenancy=${OCI_TENANCY:?Need to set OCI_TENANCY}
region=${OCI_REGION:?Need to set OCI_REGION}
key_file=${OCI_KEY_FILE:?Need to set OCI_KEY_CONTENT in OCI_KEY_FILE}
EOF
chmod 600 "$OCI_CONFIG_FILE"

# Cria arquivo de chave se não existir
if [ ! -f "$OCI_KEY_FILE" ]; then
    echo "${OCI_KEY_CONTENT:?Need to set OCI_KEY_CONTENT}" | base64 -d > "$OCI_KEY_FILE"
    chmod 600 "$OCI_KEY_FILE"
fi

# ===============================
# LÓGICA PRINCIPAL
# ===============================

echo "==> Checando health da instância primária via HTTP (${PING_RETRIES} tentativas)..."
PRIMARY_HTTP_OK=$(check_http_primary)
echo "Primary HTTP status: $PRIMARY_HTTP_OK"

PRIMARY_STATE=$(get_instance_state "$PRIMARY_INSTANCE_OCID")
echo "Primary OCI state: $PRIMARY_STATE"

BACKUP_STATE=$(get_instance_state "$BACKUP_INSTANCE_OCID")
echo "Backup OCI state: $BACKUP_STATE"

# ===============================
# DECISÃO DE AÇÃO
# ===============================

if [ "$PRIMARY_HTTP_OK" = "false" ]; then
    echo "⚠️  Primary HTTP falhou!"
    if [ "$BACKUP_STATE" != "RUNNING" ]; then
        echo "➡️  Subindo instância de backup..."
        start_instance "$BACKUP_INSTANCE_OCID"
    else
        echo "Backup já está rodando — nenhuma ação necessária."
    fi
else
    echo "✅ Primary health OK."
    # Só derruba o backup se o HTTP estiver OK
    if [ "$BACKUP_STATE" = "RUNNING" ]; then
        echo "➡️  Desligando instância de backup..."
        stop_instance "$BACKUP_INSTANCE_OCID"
    else
        echo "Backup já está parado — nada a fazer."
    fi
fi

echo "==> Status final:"
echo "Primary (HTTP) = $PRIMARY_HTTP_OK"
echo "Primary (OCI)  = $PRIMARY_STATE"
echo "Backup (OCI)   = $BACKUP_STATE"
