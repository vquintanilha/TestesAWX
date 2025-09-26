#!/usr/bin/env bash
set -euo pipefail

# ===============================
# CONFIGURAÇÃO - substituir por variáveis de ambiente
# ===============================
PRIMARY_HEALTH_URL="${PRIMARY_HEALTH_URL:-http://168.75.97.255/ping}"
PRIMARY_INSTANCE_OCID="${PRIMARY_INSTANCE_OCID:?Need to set PRIMARY_INSTANCE_OCID}"
BACKUP_INSTANCE_OCID="${BACKUP_INSTANCE_OCID:?Need to set BACKUP_INSTANCE_OCID}"
COMPARTMENT_OCID="${COMPARTMENT_OCID:?Need to set COMPARTMENT_OCID}"
DO_ACTION="${DO_ACTION:-true}"

# ===============================
# FUNÇÕES AUXILIARES
# ===============================

function check_http_primary() {
    if curl -sf -o /dev/null "$PRIMARY_HEALTH_URL"; then
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
        echo "Starting instance $instance_id..."
        oci compute instance action --instance-id "$instance_id" --action START --wait-for-state RUNNING --config-file "$OCI_CONFIG_FILE"
    else
        echo "[DEBUG] Would start instance $instance_id"
    fi
}

function stop_instance() {
    local instance_id="$1"
    if [ "$DO_ACTION" = true ]; then
        echo "Stopping instance $instance_id..."
        oci compute instance action --instance-id "$instance_id" --action STOP --wait-for-state STOPPED --config-file "$OCI_CONFIG_FILE"
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

echo "==> Checando health da instância primaria via HTTP..."
PRIMARY_UP=$(check_http_primary)
echo "Primary up? $PRIMARY_UP"

# Se HTTP falhou, verifica via OCI CLI
if [ "$PRIMARY_UP" = false ]; then
    echo "HTTP failed, verificando via OCI CLI..."
    PRIMARY_STATE=$(get_instance_state "$PRIMARY_INSTANCE_OCID")
    PRIMARY_UP=false
    if [ "$PRIMARY_STATE" = "RUNNING" ]; then
        PRIMARY_UP=true
    fi
fi

echo "Primary final status: $PRIMARY_UP"

# Checa estado do backup
BACKUP_STATE=$(get_instance_state "$BACKUP_INSTANCE_OCID")
echo "Backup instance state: $BACKUP_STATE"

# Decide ações
if [ "$PRIMARY_UP" = false ] && [ "$BACKUP_STATE" != "RUNNING" ]; then
    start_instance "$BACKUP_INSTANCE_OCID"
elif [ "$PRIMARY_UP" = true ] && [ "$BACKUP_STATE" = "RUNNING" ]; then
    stop_instance "$BACKUP_INSTANCE_OCID"
else
    echo "Nenhuma ação necessária."
fi

echo "==> Status final:"
echo "Primary up = $PRIMARY_UP"
echo "Backup state = $BACKUP_STATE"
